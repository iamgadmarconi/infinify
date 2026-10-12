# Infinify native desktop shell

## Current development evidence (2026-10-12)

The signed `42d17f4` app (executable SHA256
`395673e57097987081f4ee2cf806f26db97ae983e3ef9633772f9a40a6d83349`)
was measured with six 1700×1132-point captured sources and a 2056×1290-point
Retina output. Each phase below contains four selected seconds. FPS comes from
actual canvas drawable presentation timestamps; source delivery is separate.

| Phase | Presented fps | Worst main-thread gap (ms) | Presentation p99 / worst gap (ms) |
| --- | ---: | ---: | ---: |
| Rest | 57.25 | 2.6 | 25 / 25 |
| Pan | 51.00 | 2.0 | 25 / 25 |
| Zoom | 52.00 | 10.9 | 25 / 25 |
| Move one window | 58.00 | 2.5 | 25 / 25 |
| Switch logical focus | 52.00 | 2.5 | 25 / 25 |

The matching `0e47daa` phases had worst main-thread gaps of
46.5/48.7/63.1/41.9/25.7 ms. The new build moves child ownership/bounds validation
onto the bounded observer and caches inherited-wallpaper queries, alongside
correctness changes; this one pair does not isolate each change's contribution.
Worker results retain exact binding/session fences, fresh main-thread process
birth and a 100 ms limit measured from the first native read. Input and frame
acceptance still validate fresh native membership. The source/presentation
120 Hz assertions still fail, and drawable acquisition still reaches 25 ms.
The fixture requests 120 Hz redraws without proving 120 Hz source production.
An unchanged unrelated level-24 surface overlaps the canvas's numeric bounds;
that coverage alone does not establish optical occlusion.

A separate six-second native idle interval used six static cooperative windows
and a static background, with process/geometry reads only at the boundaries.
Infinify used 3.99% of one core, 53.66 MiB ending RSS and 155.20 MiB charged
physical footprint. The helper used 0.17%, 89.80 MiB RSS and 24.09 MiB footprint.
Whole-desktop WindowServer CPU was 11.78% in the fixture-only interval and 2.33%
in the managed interval; the former has overlapping originals, the latter a
grid plus a canvas surface, so their difference is not attributable compositor
overhead. RSS/footprint endpoints are not peaks or a complete GPU allocation
account. All six exact identities, owners, bounds, screen rectangles, transforms
and alpha values were restored, the journal was empty, and all children exited.
Idle CPU and background drawables do not prove native-window presentation FPS.

One opt-in fixture diagnostic reduced periodic status reporting from 50 to
500 ms while keeping watchdog/commands, event reports and requested animation
unchanged. On the same app it presented 48.25–56.75 fps with 25 ms worst gaps;
it did not resolve the cadence deficit. Default reporting and assertions remain
unchanged. Evidence is under
`target/performance/20261012-window-scaling/child-observer/`, with the matched
capture, idle and telemetry runs in `target/ipc/bench.J9FwIM`,
`target/ipc/idle.60ssvst0` and `target/ipc/bench.n3BfOD`. These bounded owned runs
do not establish stable 120 Hz or ordinary-application compositor parity.

The native helper and Rust runtime now use only the current binary protocol.
The legacy JSON listener/client and ignored navigation flag are removed.
The runtime's 14 focused owned-window/fault-peer cases passed, including
independent native rectangle readback, heartbeat retention, explicit and
crash-triggered restoration, and rejecting native drift before sending a frame.
The scoped resize scenario passed all 24 edges/corners at zoom 0.5, 0.8 and 1,
with 50 grabs ended. These checks do not establish physical third-party input,
captured file drag/drop or native display-boundary clipping.

Physical edge resizing passed on the signed `f7bdef71` app (executable SHA256
`f8a4b942df4f356bdfa7d678ce6130335d625263b670f4cdbf20ce99acb5076c`),
arm64/macOS 27.2. `tests/e2e/physical-resize-edge.sh --live-owned-fixture`
performed one unmodified right-edge drag inward by 24 display points at zoom
0.5 in capture mode and one in scoped primary-native mode. Each used nine real
CGEvent samples through WindowServer, with exact owned identity/owner and event
hit checks before every post. Both entered the production resize coordinator;
native widths changed from 320 to 272 points, displayed widths from 160 to 136,
and maximum sampled edge error was 0.0 points. Native matrix scale stayed 2 in
both axes. Capture edges use compositor placement with real capture accepted;
native edges use independent WindowServer rectangles. The cursor and both
original native geometries, transforms, alpha and levels were restored, both
helper journals were durably empty, and all four children exited. Evidence:
`target/ipc/physical-edge.ry_2ms4_` and
`target/physical-resize-edge-final2.log`. This covers two disposable fixture
cases, not optical pixel-edge tracking, fast/human input, other physical zooms
or third-party application acceptance.

The sections below retain earlier implementation and validation history; dated
fixture results describe their particular source revision and scope.

`./scripts/build-app.sh` builds and ad-hoc signs `target/app/Infinify.app` for
Apple Silicon / macOS 26+, and `./scripts/install-app.sh` puts a signed copy in
`~/Applications`. Neither launches anything. A normal run is the desktop, as
DriftWM is the session: one canvas panel covers each display whole, on every
Space, under the menu bar and the Dock, with no toolbar, no status line and no
chooser, and every real application window (a standard window or a dialog, not
a popup or a helper window) is on the canvas by itself.
[Desktop mode](#desktop-mode) says what that means, how the app is installed
and started at login, and how little of it has been run.
[Managed windows](#managed-windows) has the adoption rules; `--manual` keeps
the chooser and captures only the windows picked there.
Screen Recording permission is required for capture; Accessibility permission
is required for native input, for focusing a native window from the canvas and
for closing one. While either is missing a normal run shows one small window in
place of its canvas. It names what is missing and offers an Allow… button for
each: the app asks macOS for access only from that click, then opens the
matching System Settings pane. Screen Recording takes effect after a relaunch,
which the window offers. Automated probes and tests never request permissions or change privacy
settings or SIP. An ad-hoc signature changes with every build, so macOS drops
both grants on each rebuild and each reinstall; build and install with
`INFINIFY_SIGN_IDENTITY="<stable signing identity>"` to keep them.

The app links the actual Rust desktop static library. Every connected display
gets a nonactivating panel and an independently persisted camera on the shared
world. One ScreenCaptureKit stream per source feeds every display that shows
it, and one compositor layer per display draws the canvas the way DriftWM does
([Rendering](#rendering)). This is continuous live capture of native
application content.
Normal capture mode now observes each managed root's native descendants and
captures positively parented popups/sheets as separate child images. They share
the root's canvas transform, including a child visible beyond an offscreen root,
and clicks use the rendered child order with fresh identity/ancestry checks.
Child clicks preserve the application's native focus instead of raising its
parent through Accessibility. Captured mouse drags retain the original child
until all admitted buttons are released. Unparented application windows and
desktop-global menus are not inferred as descendants. This path is implemented
and source-reviewed; physical application behavior remains unverified.
The normal capture desktop also reads the managed root's actual Accessibility
green control. Clicking its captured image requests canvas fullscreen;
Option-click requests canvas fit. The event tap retains that button pair and
rechecks the rendered root on release, so a covering child cannot activate its
parent's control. Controls without readable current AX geometry are not guessed.
Admitted pen contacts keep their original root or child and display outside the
canvas, using the current camera mapping for motion and pairing release/tool-out
with that recipient. A replacement physical tool retires the previous contact.
Fresh overlay tablet input still enters through AppKit; unrelated native pen
input is not captured. Hardware validation remains outstanding.
In capture mode, ordinary native windows remain where their owners put them. Cameras and world
movement do not move, transform, park, or resize native windows.
An explicit [cooperative native backend](#native-presentation-through-a-cooperative-helper)
instead presents the fixture process's real windows through the transform helper.
It is a separate, scoped mode; the default remains capture and redraw.
`--native-desktop-helper RUNTIME NONCE_FILE` explicitly selects whole-desktop
native presentation for the login user, including applications launched later.
It requires one authenticated Apple Dock-hosted same-user helper, per-window
restoration and a scope audit. It cannot be combined with `--only-pid`,
`--windowed`, `--manual` or fixture modes. The app connects to an existing
helper; it never injects or installs one. The owner-run
[`scripts/start-native-desktop.sh`](../../scripts/start-native-desktop.sh)
prepares or reuses that helper after its policy preflight succeeds. Merely
building the script's artifacts performs no injection or window mutation.
Native clipping, cross-view drag-and-drop and physical application acceptance
remain incomplete; this explicit mode is not yet proof of full parity.
[Window navigation](#window-navigation-and-native-focus) activates and raises
the one window it focuses, and nothing else.

## Desktop mode

DriftWM is a compositor: it is the session, not an app one launches. Since
2026-10-10 a normal run of Infinify is that for macOS, as far as public API
goes: it replaces the desktop instead of sitting on it in a panel with a
toolbar. The original validation for this section used `--windowed` without
Screen Recording access, with detached placeholders only. Subsequent user-run
desktop sessions exposed interaction issues; their fixes still need user
validation and do not establish compositor or performance parity.
[What was run for desktop mode](#what-was-run-for-desktop-mode) has the
boundary.

**Reading the rest of this file.** The sections below were written while every
canvas panel carried a 64-point strip with toolbar buttons and a status line,
and a chooser window came first. A normal run has none of the four now. Where a
later section says the status line shows something, a normal run writes that
text as one line on stderr and draws nothing; where it names a toolbar button,
the same action is on its key and on `Infinify msg action`; "Choose windows"
and "Open canvas" exist with `--manual` only; "Return to desktop" is gone, and
quitting is what returns the native desktop. An output is the whole panel, not
"the panel less its strip". The dated run records are left as they were
observed, with the numbers of that build: a `--windowed 1100x700` launch
reported an output of 1100x636 and the view centre `550 -318` then, and reports
1100x700 and `550 -350` now. The probe, demo and owned-fixture modes
(`--demo*`, `--owned-resize-*`, `--source`) keep their panel, strip, toolbar,
status line and chooser unchanged.

### What a normal run is

- **Edge to edge.** One borderless, nonactivating panel per display covers the
  display's whole frame (`NSScreen.frame`, not the visible frame), and that
  same rectangle is registered as the display's output. Placement, centering,
  fit and fullscreen use an inset area below the menu bar and notch. The Dock
  remains an overlay and reserves no bottom or side gap.
  Both stay: the panel's level is the floating level (3 on this Mac),
  above every ordinary window and below the Dock (20) and the menu bar (24),
  so both go on drawing over the canvas and taking their own clicks. Neither
  is hidden, and no presentation option or system setting is touched. Hot
  corners are the display's true corners, the two top ones under the menu bar
  ([Displays, hot corners, layouts and autostart](#displays-hot-corners-layouts-and-autostart)).
- **Every Space.** The panels are on all Spaces, a fullscreen application's
  included, and stay put through a Space switch: collection behaviour
  `CanJoinAllSpaces | Stationary | IgnoresCycle | FullScreenAuxiliary`. That is
  public API only. No private window tag is set, and whether Mission Control
  leaves the panel out of its window thumbnails was not observed.
- **No chooser.** With both grants the launch goes straight to the canvas and
  adopts the windows that exist ([Managed windows](#managed-windows)). With
  Screen Recording or Accessibility missing, one small window comes instead:
  it says which is missing, has an Allow… button for each (the request to
  macOS, then the matching pane of System Settings, from that click only),
  Relaunch and Quit, looks again once a second, and opens the canvas by itself
  as soon as both are there. Stage Manager on holds the launch at the same
  window ([Limits of desktop mode](#limits-of-desktop-mode)). macOS gives Screen Recording only to a process
  started after the grant, so the window says so and Relaunch starts the run
  again: the same executable with the same arguments, in the same process,
  after the usual cleanup, so a run started by the login item stays the login
  item's. A saved scene that could not be loaded is shown in the same window
  with Quit alone. Autostart commands run when the canvas opens, not while this
  window is up, so a relaunch does not start them twice.
- **Status notes go to stderr.** What the status line used to flash ("Bookmark
  2 saved", "Zoom limit reached", a refused shortcut, a window that was not
  adopted, `Windows are not managed: …`) is written to stderr, one line each,
  and nothing is drawn for it. A note is not written again while it stays up:
  a flashed one for two seconds, counted again from each renewal, so one that
  is renewed before it expired is one line. Once it has expired the same text
  is a line again: two identical refusals a minute apart are two events. A
  failed read of the window list, which is tried again about every two
  seconds, is one line per distinct reason. The summary of registered chords
  the status line rested on is not written at all. What a config file has
  wrong is drawn in the error bar, as before
  ([Blur, window animations and the error bar](#blur-window-animations-and-the-error-bar)).
- **Quitting returns the native desktop.** Control-Option-Escape (until a
  binding takes that chord), a key bound to `quit` (DriftWM's default is
  Control-Command-Shift-Q), `Infinify msg action quit`, SIGTERM and a
  log out all end the same way: fullscreens ended, the scene saved, panels
  closed, capture stopped, hot keys released, exit status 0. There is no Quit
  button and no Return to desktop. `msg quit` is not a command: the action is
  `msg action quit`.
- **It stays up.** When the Mac or its displays wake, when the login session
  becomes active again (the lock screen was left, a user switched back) and
  when the active Space changes, each panel is put back on its display's
  rectangle and in front of ordinary windows; nothing is closed and no output,
  hot key or gesture is touched. System-interrupted captures retain their logical
  binding and last picture, then retry with a freshly listed shareable window.
  Wake/session return makes a pending retry due immediately. Retries back off
  from 250 ms to 30 seconds; each refresh and start has a two-second deadline,
  and late callbacks cannot replace a detached or reused process/window identity.
  Permission refusals, an explicit user stop and invalid capture arguments remain
  terminal. No permission is requested. Only when the displays are no longer
  the ones the panels were made for are they rebuilt, the way a display change
  rebuilds them. A moment with no display at all leaves the desktop open with
  no panel, and it is rebuilt when a display is there again. Discovery goes on
  by itself, driven by the poll and by the window events, which observe the
  change of Space on their own account and look for windows at once
  ([Event-driven tracking](#event-driven-tracking)). A rebuild keeps the window
  manager and its observers; the hot keys and the tap monitors stop and start
  again with the panels, and the frame timer is made again by the next frame
  that is wanted.

### Flags that change it

- `--windowed [WIDTHxHEIGHT]`: the canvas in one ordinary window instead, all
  of it canvas: the output is the whole content area, with no strip. It opens
  at launch with whatever access there is and never shows the permission
  window, registers no global shortcut, and ends by `Infinify msg action quit`
  or a signal (Control-C in its terminal). See
  [Nested development window](#nested-development-window).
- `--manual`: the chooser first, as it always was, and nothing is adopted. The
  chooser now stays open above the canvas, the one place a window is added or
  rebound from; closed there, it is gone for the run. Its Rebind list is made
  again by Refresh and after every Add: a placeholder that arose during the
  run (a source that closed) is offered after a Refresh, and a slot that was
  just rebound is not offered again. `--manual --windowed` opens the canvas at
  launch and the chooser above it.
- `--only-pid PID[,PID…]` with `--windowed`: only the windows of the named
  processes are managed, with or without Screen Recording access. See
  [Managing only named processes](#managing-only-named-processes).
- `login-item on | off | status`: see below. Handled before AppKit starts, like
  `msg`: no window, no privacy grant.
- `--demo*`, `--owned-resize-*`, `--source`: unchanged.

### Installed, signed, started at login

These are for the owner to run. No agent, script or test installs the app,
registers the login item or signs with a real identity, and none of the three
steps below was run for this document.

1. `./scripts/install-app.sh` builds the bundle (`--built` takes the one
   already in `target/app`), copies it to `~/Applications/Infinify.app` and
   signs the copy: with `$INFINIFY_SIGN_IDENTITY` when that names a
   code-signing identity (`security find-identity -v -p codesigning`), else
   (unset, empty or `-`, which is how `codesign` spells ad hoc) ad hoc with a
   loud warning, because macOS ties both privacy grants to the signature and
   an ad hoc one is new at every install. The bundle in place is moved aside
   whole and then removed, never overwritten file by file; an install that
   fails or is interrupted before the new copy is in place puts it back. It
   starts nothing and registers nothing.
2. `~/Applications/Infinify.app/Contents/MacOS/Infinify login-item on`
   registers the LaunchAgent the bundle carries at
   `Contents/Library/LaunchAgents/com.marengox.infinify.agent.plist`, through
   `SMAppService`, and launchd starts it at once. macOS may ask for approval
   under System Settings > General > Login Items & Extensions. The agent runs
   the bundle's own executable with `RunAtLoad`, `KeepAlive` with
   `SuccessfulExit = false`, `LimitLoadToSessionType = Aqua` and
   `ProcessType = Interactive`: started at login, started again after an end
   that is not exit status 0, and left alone after a quit.
3. `login-item status` prints `login item: on`, `off` (with `never registered
   from this bundle` before the first `on`) or that approval is waited for,
   and registers nothing; `login-item off` unregisters, which ends
   the instance launchd started, and where nothing is registered (never, or
   not any more) it only says `off` and exits 0. Anything else exits 64 with
   the usage line.

Because `login-item on` starts an instance at once, quit one that was started
by hand first (`Infinify msg action quit`): nothing stops two from running, and
the second has no socket and its own set of panels. After a quit the login item
stays registered and starts again at the next login, or at once with
`launchctl kickstart gui/$(id -u)/com.marengox.infinify.agent`.

Exit status: 0 for the quit action, `msg action quit`, the exit chord, a
signal, a log out, and Quit in the permission window. An abnormal end is not 0,
so launchd starts the app again: a crash, a relaunch whose `exec` failed (1),
and the Application Support directory that could not be created (2), which
therefore loops at launchd's restart interval until the directory can be made.
A run started by launchd has launchd's environment and no terminal:
[CONFIG.md](../../crates/desktop/CONFIG.md#started-at-login) says what that
changes for the config path, `exec-terminal`, `PATH` and relative paths.

### What changes for someone who used the previous build

- No toolbar: Home, Fit, the zoom buttons, Center, Previous and Next are their
  keys or `Infinify msg action …`. No status line: confirmations and refusals
  are stderr lines, which a run started at login does not show anywhere.
- No Return to desktop and no Quit button: quit as above.
- The canvas reaches the top of the display and the bottom, under the menu bar
  and the Dock. A window centred by `center-window` is centred on the display,
  not on the area below a strip, and `fill-window`, `fit-window` and
  fullscreen ask for the display's whole size.
- The canvas no longer opens with Screen Recording alone: both grants are
  asked for first, since a panel that covers every window would otherwise
  leave nothing clickable. `--windowed` still opens with whatever there is.
- In scripts, a `--windowed 1100x700` output is 1100x700 with its view centre
  at `550 -350` where it was 1100x636 and `550 -318`.
- The chooser appears only with `--manual`, and then stays open.

### Limits of desktop mode

- **The canvas covers every window, and a covered window stops drawing.**
  macOS tells a window that lies wholly under an opaque window that it is
  not visible, and applications stop drawing one that is not: on the
  owner's runs of 2026-10-10 typing reached a window under the canvas and
  its tile showed none of it until the canvas was gone. The panel now has
  an alpha value of 0.999. On a fixture window under a floating panel that
  kept the window reported as visible, where declaring the panel and its
  layers non-opaque had not. Under an opaque floating panel a WKWebView page
  and an Electron page stopped drawing altogether (no animation frame in two
  seconds, `document.visibilityState` hidden); under the canvas window of a
  windowed run they drew at their full rate, and `tests/e2e/scoped-windows.sh`
  asserts that on every run. On the owner's own applications in a desktop
  run it has not been observed yet. The intended design is the other way
  round, the window server placing the real windows with nothing over them
  (`native/privileged`, needs System Integrity Protection relaxed by the
  owner); this panel is what runs until that exists.
- **A click reaches a window only once its application is in front.** An
  event posted to an inactive application is dropped by everything but a
  control that takes a first click (measured on a WKWebView and an Electron
  window). An unbound press therefore waits until the native focus its
  click asked for is answered, at most half a second, with its drags and
  release queued behind it; on the window that already has native focus it
  goes at once. `INFINIFY_DEBUG=1` in the environment prints one stderr
  line for each such press and each native focus request, and one every two
  seconds that says how the canvas is keeping up
  ([the frame line](#managing-only-named-processes)).
- **Stage Manager has to be off.** With it on, macOS keeps only the current
  stage's windows at their size and scales every other window into a
  thumbnail in its strip. The window's bounds, its picture and the place a
  click has to go are then the thumbnail's, and every application switch
  swaps which windows that is. This was seen on the first runs on real
  windows (2026-10-10): tiles blurred and still, clicks that did nothing, a
  capture size that swung between about 150 by 170 and the window's own. A
  normal launch therefore reads `com.apple.WindowManager` `GloballyEnabled`
  and, while it is on, shows the small window with that said and a button
  that opens Desktop & Dock; it never writes the setting, and it opens the
  canvas as soon as it is off. Switched on under a running canvas it is named
  once on stderr and the run goes on. `--windowed` and `--manual` launches
  are not held. That the canvas works on real windows with it off has not
  been observed yet.
- **A window on another desktop (Space): addressed, never run.** A window
  left on a desktop that is not the one shown is in no Accessibility list, so
  a click on its tile used to do nothing (`native focus … outcome=missing_window`,
  fourteen times in the owner's run of 2026-10-10, after opening Safari had
  made macOS switch desktops). For exactly that answer, and only while the
  window server still lists the window as that process's and as not on
  screen, the focus adapter
  now brings the window forward by its window number the way yabai does
  (`native/focus/focus.m`, `forward()`), waits for it to appear in the
  Accessibility list, and goes on as for any window; the trace line ends
  `brought_forward=1`. Nothing here can put a test window on another desktop,
  so this has not run once: `tests/e2e/scoped-windows.sh` shows only that
  windows on the shown desktop are focused as before. What to expect if it
  works: macOS slides to that window's desktop, the canvas comes along, and
  the windows left behind stop drawing until one of them is clicked and macOS
  slides back. What may differ: the
  slide may outlast the 1.5 seconds a focus request has, or another
  application may be in front for a moment and end the request, and then the
  first click only changes the desktop and the second focuses the window.
- **Capture after sleep or lock is not restarted.** If macOS stops a window's
  capture stream with an error, the window becomes a stand-in and is not
  offered again until its native window has left the screen and come back.
  Whether streams stop across sleep, lock or a user switch was not observed.
  The panels and discovery do come back.
- **Status notes are lost at login.** The LaunchAgent names no file for
  stderr (a bundled property list cannot name one under the home directory),
  so launchd discards it. Start the app from a terminal to read the notes.
- **Two instances are possible**, as said above.
- **Cursor edge pan does not pan upward under the menu bar.** The top
  `cursor_zone` (20 points by default) lies under the menu bar, where a press
  would not reach the panel, so no output is reported there and nothing pans;
  the same holds over the Dock. A `cursor_zone` taller than the menu bar
  leaves a band that does. Read from the code, not run
  ([MOTION.md](../../crates/desktop/MOTION.md)).
- **macOS's own "Quit & Reopen"**, which System Settings offers after Screen
  Recording is switched on, reopens the app through LaunchServices, outside
  the login item's job: it is then not restarted after a crash until the next
  login. The permission window's Relaunch stays inside the job.
- **A moment with no display** ends every DriftWM fullscreen: the controller is told that every output is
  gone ([FULLSCREEN.md](../../crates/desktop/FULLSCREEN.md)).
- **Other applications' floating palettes.** The panels are put in front again
  at every Space change, which also puts them above another application's
  floating-level palette until that application orders it front again.
- **macOS keeps its own gestures and corners.** Mission Control, the system's
  hot corners and the Dock still answer where they did; Infinify changes no
  setting.
- **A status text made of several notes is one line more.** Where the status
  line would have shown a summary (`Shortcut unavailable: X (+1 more)`) or two
  notes joined by ` · `, that text is written after its parts: a launch with
  two refused chords, or a `--windowed` launch with neither grant, writes one
  line more than it has notes. Read from the code, not run.
- **Stale wording in one stderr line.** A window of 200x150 or more that is
  left out is still reported as `… not adopted: …. Choose windows adds it by
  hand.`, which holds with `--manual` only.
- **Unverified system behaviour:** `SMAppService` with an ad hoc signature and
  after a reinstall, the `launchctl kickstart` hint, `exec` of a process that
  has already started AppKit (Relaunch), and the quit at log out.

### What was run for desktop mode

2026-10-10, this build, on a Mac with one built-in display (macOS 27.2, Apple
Silicon).

- `./scripts/build-app.sh`: built and ad hoc signed, with the LaunchAgent at
  `Contents/Library/LaunchAgents`; `codesign --verify --strict` passed.
- The controller's `cargo fmt --check`, `clippy -D warnings` and its
  `controller_flow`, `lifecycle_flow`, `navigation_actions_flow`,
  `platform_actions_flow`, `render_flow`, `pointer_flow`, `ipc_flow` and
  `config_flow` modules: 95 scenarios, none failed. None of them is about
  desktop mode: no command changed shape.
- Five launches as `--windowed 1100x700` with a private `--state` (three
  detached placeholders), `--config` and `--socket`, each under 30 seconds and
  without Screen Recording access. Accessibility was evidently trusted for the
  session that started them: a canvas opened without it writes `Native window
  focus needs Accessibility access: …` to stderr, and no launch did. With
  detached placeholders only, no native focus and no input was attempted. All
  five were of the sources as they stood before the `login-item status`
  wording below was shortened; the config of the last two also held an
  `autostart` command:
  - `msg state`: `outputs 1`, `* windowed camera 550 -350 zoom 1 1100x700`,
    and the three placeholders. The saved scene holds the output's
    `screen_bounds` as 1100x700.
  - `msg screenshot -o FILE`: a PNG of 1100 x 700 pixels, looked at: the dot
    grid edge to edge and the Notes placeholder with its top-left corner at
    (200, 150), no strip. After `msg action "center-nearest right"`, `msg
    camera` read `1950 -0`, `msg focus` named the Browser placeholder, and a
    second capture shows it from (100, 50) to (1000, 650): centred in the
    whole 1100x700.
  - stderr of each run held one line, `Windows are not managed: Infinify has
    no Screen Recording access. A run without --windowed asks for it.` In one
    run `msg relaunch --id 1`, for a placeholder whose bundle
    identifier no application has, added `Relaunch failed: no application with
    bundle identifier "org.example.seed" is installed`, once, and nothing when
    the note expired two seconds later.
  - In the last two launches an `autostart` command that appends a line to a
    scratch file ran once per launch, with `INFINIFY_SOCKET` set to the served
    socket.
  - `msg action quit` answered `ok` and the app exited with status 0 (read in
    two launches; a third was ended the same way but its status was lost to a
    mistake in the driving script); `kill -TERM` ended the other two, also
    with status 0. The socket file was gone each time. `msg quit` exits 2,
    `unrecognized subcommand`.
- `Infinify login-item status` from the built bundle printed `login item: off
  (never registered from this bundle)` and exited 0: macOS answers "not found"
  for an agent it was never told of, although the bundle carries the property
  list. `launchctl print` afterwards found no such service. `login-item` with
  no argument, with `maybe` and with `status extra` printed the usage line and
  exited 64. The app was built once more for that one string and not launched
  again.
- The window levels were read with a five-line C program: normal 0, floating
  3, Dock 20, main menu 24.
- After the review fixes of the same day (the `--manual` chooser's Rebind
  list, when a status note is written again, `login-item off` where nothing is
  registered, the install script's interrupt handling and `-`, the chooser of
  `--manual --windowed`): the same eight modules again (95 scenarios, none
  failed), a rebuild, and two more `--windowed 1100x700` launches on the same
  private paths with the scene seeded afresh, again without Screen Recording
  access and with no missing-Accessibility note:
  - The first repeated the checks above with the same results: `msg state`
    (`* windowed camera 550 -350 zoom 1 1100x700`), two captures of 1100 x 700
    pixels, looked at (the Notes placeholder from (200, 150), then the Browser
    placeholder from (100, 50) to (1000, 650), the dot grid to every edge),
    `center-nearest right` to `1950 -0`, and `msg action quit`: exit status 0,
    socket gone. Its stderr held the one `Windows are not managed: …` line.
  - The second asked `msg relaunch` for three placeholders of one bundle
    identifier that no application has: `--id 1`, 3.2 seconds later `--id 3`,
    half a second later `--id 2`. All three answered `ok`. stderr held two
    `Relaunch failed: …` lines: one for the first, one for the second, which
    came after the first note had expired, and none for the third, which came
    while the second was still up. A review launch of the build before the
    fix had written one line for the first two. `kill -TERM` ended it with
    exit status 0 and the socket gone.
  - `login-item status` printed `login item: off (never registered from this
    bundle)` again and exited 0.
  - `scripts/install-app.sh` was not run. Its cleanup function and signal
    traps were lifted into a stand-in script over scratch directories and run
    under `/bin/sh` and `/bin/dash`: interrupted before the first rename and
    between the two, the stand-in for the installed bundle was the old one
    again; interrupted after the second, the new one; nothing was left beside
    it in any case.

**At the merge with the tap bindings, the background caches and event-driven
tracking, the same day.** Everything above ran on the tree desktop mode was
built in, which had none of the three. The tree that landed has the
[tap tracker](#tap-bindings), the [background caches](#background-caches) and
the [window events](#event-driven-tracking) beside it.
`./scripts/build-app.sh` compiles each shell file once (`login-item.m`,
`onboarding.m` and `session-watch.m` beside `window-events.m`, `tap-keys.m`,
`frame-driver.m` and `background-tiff.m`), copies the LaunchAgent into the
bundle and built it as written, ad hoc signed; `codesign --verify --strict`
passed.

- **Read at the join**, in the code, not run:
  - One start. With both grants the launch opens the canvas, and opening it
    starts the hot keys with the tap monitors, then the navigation
    coordinator, then the window manager with its observers, as before
    desktop mode. With a grant missing the permission window is all there is:
    the config is loaded and its tap table kept, but no key is registered, no
    monitor is installed and no window manager or observer exists. When the
    window hands over, which it does once, the same start runs, once.
  - One end. The quit action, `msg action quit`, the exit chord, SIGTERM and
    a quit AppKit asks for (log out) all reach `-cleanup`, which runs once:
    the window manager with its observers, the session watch, the hot keys
    and the tap monitors stop first, then the frame timer with the
    coordinator, then every capture stream, and the exit status is 0. The
    two changes the join made to the shell's code are there: `-cleanup` and
    `-dealloc` stop the session watch and the tap monitors both.
  - The active Space. Two objects observe its change, each registered once:
    the session watch, which puts the panels back in front, and the window
    events, which have every application list its windows again and run a
    discovery pass. Both happen at every change, in no fixed order.
  - A rebuild of the panels (a display change, or a wake that finds other
    displays) stops the frame timer and the coordinator and stops and starts
    the tap monitors with the hot keys; the frame timer is made again, on the
    new panels' screens, by the first frame that is wanted; the window
    manager with its observers and the session watch are kept.
  - Notes. The three milestones added no stderr line to `main.m`: theirs are
    written where they arise (a cache over its budget, by the background
    module) and are no status note, so nothing is written both directly and
    by the rule above that writes a status note once. A window the adoption
    test leaves out is still named by the window manager's own line, with
    its stale last sentence ([limits](#limits-of-desktop-mode)).
  - Geometry. Nothing the three added converts between a panel and its
    output: hover, the lost-input release and the looks an event starts read
    the output's `screen_bounds`, which is the whole panel now. The fixture
    modes' panels, strip and view code are byte for byte what they were.
- **The controller**, thirteen test modules through the exported C ABI, all
  passing: the eight above and `usable_tap_flow` (15), `motion_flow` (11),
  `effects_flow` (5), `passthrough_flow` (19) and `rules_flow` (26), 179
  scenarios with `lifecycle_flow` at 32; `cargo fmt --check`,
  `clippy -D warnings` and `./tests/e2e/desktop-navigation.sh`.
- **The app, two launches** of the landed build, `--windowed 1100x700`, on a
  private scene of three seeded slots, a config holding an `alt+shift` tap
  and a private socket, four seconds and one, without Screen Recording
  access and with no missing-Accessibility note:
  - `msg state`: `* windowed camera 550 -350 zoom 1 1100x700` and the three
    placeholders; `focus` answered `(none)`.
  - Two viewport captures of 1100 x 700 pixels, looked at: the dot grid to
    every edge with no strip, the Notes placeholder from (200, 150), and
    after `action "center-nearest right"` (camera `1950 -0`, `#2` focused)
    the Browser placeholder from (100, 50) to (1000, 650).
  - `action "pan-viewport right"` settled on `2050 -0`; `action zoom-to-fit`
    on zoom `0.28484848484848485` at camera `750 -390`, and again back on
    zoom 1 at `2050 -0`; `action reload-config` answered `ok`.
  - stderr of each held one line, the `Windows are not managed: … A run
    without --windowed asks for it.` note: no warning for the tap binding
    and no note twice.
  - `msg action quit` ended the first with exit status 0, `kill -TERM` the
    second with exit status 0; the socket file was gone each time.
- `login-item status` from that bundle printed `login item: off (never
  registered from this bundle)` and exited 0, and `launchctl print` found no
  such service afterwards. `sh -n scripts/install-app.sh` passed; the script
  was not run.

Those two launches were windowed and had no Screen Recording access: no hot
key, tap monitor, session watch, window manager or observer existed in them,
so nothing read at the join was run, no tap was made and no window event
arrived. Everything below is as unrun on the landed tree as it was before.

Not run, and so known only from the code: a normal run on a display (the
whole-display panel, the menu bar and the Dock over it, real windows under
them), any second Space, a fullscreen application's Space and Mission Control,
sleep and wake, lock and unlock, a display added or removed, the permission
window (its layout, its Allow buttons, the re-check, Relaunch and its `exec`),
a launch with real grants, `--manual` with its chooser above the canvas (its
Rebind list after a Refresh, a rebind and a source that closed, and the
chooser of `--manual --windowed`), hot
corners at the display's corners, the quit at log out,
`scripts/install-app.sh`, `login-item on` and `off`, the LaunchAgent under
launchd, a restart after a crash, and signing with a real identity.

## Controls

A normal run has no toolbar, no status line and no button: everything below
is a key, a pointer gesture or `Infinify msg`. What the status line used to say
is a line on stderr ([Desktop mode](#desktop-mode)).

- The chooser, with `--manual` only. Add selected window: add a selected native
  source, or explicitly rebind a saved placeholder using the chooser's
  drop-down, which lists the world windows that have no source and is made
  again by Refresh and after every Add. Same-source duplicate attachments are
  rejected; the existing world
  window is visible through every display camera. Open canvas: show the saved
  world without adding a window, at its saved cameras only with `[session]
  restore_camera = true` (see [Persistence](#persistence-and-lifecycle)).
  Placeholders, panning, zooming and the view actions need no capture, so this
  works before any source is chosen and without Screen Recording access; a
  canvas opened this way manages no window. The chooser stays open above the
  canvas. A run that manages windows by itself has no chooser: a window it did
  not take, or one whose capture failed, cannot be added by hand there.
- Close and suspend: Command-Q (`close-window`) asks the focused window's
  application to close it, by pressing that window's own close button through
  Accessibility; on a focused placeholder it dismisses the placeholder.
  `suspend-window` (no default key) does the same and leaves a stand-in behind.
  `Infinify msg close`, `suspend` and `relaunch` are the scripted forms. See
  [Managed windows](#managed-windows).
- Keys, pointer gestures and settings come from one TOML file in DriftWM's own
  grammar; [Configuration](#configuration) has the file, the modifier mapping
  and the default tables. With no file, DriftWM's default bindings apply. The
  chords named in this list are those defaults under the default super chord
  (Command). Nothing on screen lists the chords the running app
  resolved, now that the status line and the toolbar's tooltips are gone:
  `Infinify --help` and the default table under
  [Configuration](#configuration) have them, three of which start a program.
- Tap bindings: a `[keybindings]` entry that is a bare modifier chord, such as
  `"alt+shift" = "switch-layout next"`, runs when the chord is pressed and let
  go with nothing else pressed in between. DriftWM's defaults bind none, so
  there is none until the config file writes one, and a normal run only.
  [Tap bindings](#tap-bindings) has the rule, what it needs of macOS, and that
  no chord has yet been pressed against it.
- Pan a display's camera: drag or two-finger scroll on empty canvas,
  Command-drag anywhere, or a three-finger swipe
  anywhere. A pan that is still moving when the fingers lift or the button is
  released keeps drifting until friction stops it (`navigation.drift`; 0 turns
  that off). Zoom, pointer-anchored, up to 1.0 and down to half the zoom that
  fits every window: mouse wheel on empty canvas, Command-wheel or
  Command-two-finger-scroll anywhere, a two-finger pinch anywhere,
  or a three-finger pinch anywhere. The view actions below are the animated
  keyboard equivalents; [Camera motion](#camera-motion) has the
  details of drift, edge pan and the pointer speeds, and
  [Trackpad gestures](#trackpad-gestures) the rest of the gesture table and
  what macOS must be told first.
- View actions: while panels are open, the global hot keys bound to
  `zoom-to-fit` (Command-Tab or F3, again to return), `home-toggle` (Command-A), `zoom-to-fit` (Command-W; press
  again to return), `zoom-in` (Command-=), `zoom-out`
  (Command--), `zoom-reset` (Command-0 or Command-Z) and
  `pan-viewport <direction>` (Control-Command with an arrow key, one
  `navigation.pan_step`). Hot keys act on the display under the pointer, or
  the first display when the pointer is over no panel. The toolbar buttons
  Home, Fit, −, 1:1 and + exist in the demo panel only, where they act on the
  viewport last clicked, scrolled or pinched, else the first.
  Home goes to the origin at 1:1 and Fit frames every window, detached
  placeholders included, together with any `navigation.anchors`; a second press
  returns to the view left, and any other pan or zoom forgets the Fit return.
  Zoom in stops at 1:1. Zoom out stops at half the zoom that fits all windows
  and does nothing if the view is already further out than that. A pointer
  press stops every display's flight, and its drift, where it is. A scroll that
  pans, or a trackpad swipe or pinch that is bound, stops the flight and the
  drift of the display it is on, and a wheel zoom replaces that display's
  flight with its own animated zoom. A scroll that is forwarded to a window,
  has no delta, or is already at the zoom limit leaves the flight alone, and so
  do a hold and an unbound gesture. One unbound gesture does stop it, as
  upstream's does: a swipe right after a three-finger tap, once a
  `doubletap-swipe` binding is found for it, even with no window under the
  pointer to grab and no plain swipe bound.
- Window navigation, in every normal run (the hot keys only while panels are
  open and not with `--windowed`, where `Infinify msg action` runs the same
  actions):
  Command with an arrow key (`center-nearest <direction>`) focuses the
  nearest window in that direction and flies the camera to it at the current
  zoom; Command-C (`center-window`) centres the focused window, or the
  one nearest the middle of the view, at 1:1; Command-X (`focus-center`)
  does the same for the window under the pointer; Option-Tab and
  Option-Shift-Tab (`cycle-windows forward` / `backward`) step through the
  windows most recently focused first, and letting go of Option commits the
  choice. On a trackpad a four-finger swipe is `center-nearest` in the direction
  the canvas would follow the fingers (fingers left look right) and a
  four-finger hold is `center-window`, see
  [Trackpad gestures](#trackpad-gestures). A click on a window gives it canvas focus and starts its native
  focus, then the click is forwarded; a click on empty canvas unfocuses, and
  focusing a canvas window in its own application (Command-Tab, the Dock) is
  followed by the canvas. Focusing means logical focus, raising in the canvas,
  and, when Infinify has Accessibility access, activating and raising the real
  window.
  [Window navigation and native focus](#window-navigation-and-native-focus) has
  the rules, the flags and what has and has not been run.
- Pointer motion, in every normal run: moving the pointer over a window, with
  no button down, is delivered to that window's application
  (`--no-hover-forwarding` turns the delivery off). With
  `focus_follows_mouse = true` the window under the pointer also takes the
  focus, without being raised and without the camera moving: a screen-pinned
  window before the canvas beneath it, and never a widget. With
  `[zoom] interact_min` set and the view zoomed out below it (pick mode), a
  window on the canvas is one target: a click flies to it at 1:1, a drag moves
  it, and no click, scroll or motion reaches its application; a screen-pinned
  window and a widget are not picked and stay as they are.
  Control-Command-drag
  (`center-nearest` as a mouse binding) steps to the nearest window the way the
  drag pulls the canvas: drag left to go right. Both settings are off by
  default. None of this has been tried with a real pointer:
  [Pointer motion, sloppy focus and pick mode](#pointer-motion-sloppy-focus-and-pick-mode)
  has the rules and the exact boundary.
- Bookmarks: Command-1 to 4 (`go-to-bookmark N`) fly the camera of the
  display under the pointer to bookmark 1 to 4 (zoom is left alone and any Fit
  return is forgotten); Command-Shift-1 to 4 (`set-bookmark N`) save the
  usable-area centre of the current view as that bookmark. Pressed while a pan
  step or a bookmark jump is still flying, they save where it is heading. During
  a Home, Fit or zoom flight the saved point is not reliably the destination,
  here as upstream (mid-flight it is whatever point is passing under the
  centre), so let those land first. A line on stderr confirms ("Bookmark 2
  saved") or says the bookmark is missing ("No bookmark 2 yet", with the chord
  that sets it when one is bound). A bookmark holds a canvas position only,
  never a zoom. There is one registry of bookmarks for every display. It starts
  from the config's `[navigation.bookmarks]`, or from DriftWM's four corner
  bookmarks `1` to `4` at (±1750, ±1750) when the file has no such table;
  [Persistence](#persistence-and-lifecycle) says what a restart keeps. These are
  global hot keys only: with `--windowed`, use `Infinify msg bookmark` or
  `Infinify msg action` below.
- Every hot key and every mouse binding that names an action runs an upstream
  action string through the same controller
  command as `Infinify msg action`. Camera motion is animated with the
  controller's upstream-derived lerp at `navigation.camera_speed`. The view
  and bookmark actions move cameras only; they never move, resize, focus or
  otherwise touch native windows. The window navigation actions also focus a
  window. If macOS refuses a hot key stderr names every one (`Shortcut
  unavailable: ⌃⌥A (home-toggle)`), at launch as at a reload, and `Infinify
  msg action` still runs the action. Control-Option-Escape calls the
  shell's quit directly instead of sending the `quit` action, so exit never
  depends on the controller or on an active output. Control-Option-Escape stays
  the exit chord unless a config binding resolves to that chord, which then
  takes it. DriftWM's own `quit` binding, `mod+ctrl+shift+q`, is
  Control-Command-Shift-Q. The experimental resize controls below keep
  their own gate.
- Option-drag on a window: move the logical world window, using Rust snapping
  and hysteresis with the `[snap]` settings. Add Shift to move its connected
  cluster. The press raises and focuses the window first, as DriftWM's does,
  and so does Option-right-drag, the resize binding
  ([Upstream behaviour gaps closed](#upstream-behaviour-gaps-closed)). Held within `navigation.edge_pan.zone` (100 points) of the edge of
  the display the drag began on, the drag pans the canvas under the window,
  faster the nearer the edge. A three-finger tap followed by a three-finger
  swipe on a window moves it the same way, edge pan included. Command-Shift with an arrow key
  (`nudge-window <direction>`) moves the focused logical window by
  `navigation.nudge_step` world points. None of this moves a native window.
- Window sizing. Command-Shift-W (`zoom-to-fit-snapped`; also
  Command with a four-finger pinch in) frames the focused window's snap
  cluster and nothing else, and a second press returns, as Fit does for every
  window. It moves a camera only and runs in every normal run. DriftWM's
  actions that give a window a new size are a different matter: `fit-window`
  (Command-M, Option-middle-click, Option with a two-finger pinch on a
  window), `fit-window-snapped` (the same with Shift), and `fill-window`,
  `grow-window <direction>` and `shrink-window <direction>` (no default
  binding), with `Infinify msg resize WIDTH HEIGHT`, run in every normal run, with
  no flag: the size is asked of the real window and read back from it, and the
  canvas takes the size the window ended at.
  [Window sizing actions](#window-sizing-actions) has what each does, and what
  has been run: disposable fixture windows and an Electron window, not yet any
  application of the owner's.
- Fullscreen, DriftWM's and not macOS's: Command-F, Command with
  a middle click on a window, or Option with a three-finger pinch in or out on
  a window (`toggle-fullscreen`) gives the focused window its whole display,
  alone, on the canvas's own Space; a second press puts the window, the camera
  and the zoom back. It ends by resizing a real window, as the sizing actions
  do, and runs in every normal run with no flag.
  [Fullscreen](#fullscreen) has the rules, how it differs from macOS's own
  full screen, and what has been run: fixture windows, not yet any application
  of the owner's.
- Cursor edge pan, off by default: Command-E (`toggle-cursor-pan`)
  turns it on or off for the run, and `navigation.edge_pan.cursor_pan = true`
  starts with it on. While it is on, a bare pointer resting within
  `cursor_zone` (20 points) of a display's edge pans that display's view,
  except under the menu bar and the Dock ([Desktop mode](#limits-of-desktop-mode)).
  The toggle writes no status note.
- Command-Option with an arrow key (`send-to-output <direction>`)
  moves the focused logical window into the view of the display on that side,
  where a navigation on that display would park it. `send-cursor-to-output
  <direction>` (no default key) moves the pointer to the centre of that display.
  With one display, or none on that side, both do nothing. See
  [Displays, hot corners, layouts and autostart](#displays-hot-corners-layouts-and-autostart).
- Hot corners: an `[[outputs]]` entry of the config file can bind an action to
  each corner of a display. It runs once when the pointer arrives in the corner
  and is armed again when the pointer leaves. None is bound by default.
- `switch-layout next`, `prev` or `<index>` (no default key) selects another of
  the keyboard input sources already enabled in System Settings.
- An unbound click, drag or scroll on a window is forwarded through Rust inverse
  hit mapping to the selected native source. With DriftWM's defaults that is
  every unmodified one, with the left, right or middle button. An unbound press
  first focuses the window (click-to-focus, see
  [Window navigation and native focus](#window-navigation-and-native-focus));
  a detached placeholder is focused the same way and receives nothing. The original
  application owns keyboard focus, text editing, shortcuts, and IME; the overlay
  does not emulate a text field. Right and middle buttons travel the same
  validated per-window route as the left one, down, drag and up. Whether real
  applications accept them there has not been tried, and a context menu, if one
  opens, opens at the native window's real screen position, not in the canvas.
  An unbound press on empty canvas does nothing, as upstream. A press there
  that is bound to pan (the default left button) and is released within 5
  points of where it went down leaves no window focused, as upstream's pan
  grab does.
- Pin to screen: Command-T (`toggle-pin-to-screen`) fixes the focused
  window to its display, where it ignores pan and zoom and is drawn above the
  canvas windows; pressed again it returns the window to the canvas at the same
  place. Option-drag (the move binding) moves a pinned window about its
  display's screen, and so does the trackpad move gesture. A config file's
  `[[window_rules]]` can pin a window as it appears, make it a widget that
  stays put below the others, place it, set its opacity, or hand it key
  combinations and mouse presses that are otherwise Infinify's (`pass_keys`,
  `pass_mouse`). See
  [Window rules, widgets and pinned windows](#window-rules-widgets-and-pinned-windows).
- Control-Option-click a detached placeholder dismisses it only while no mouse
  binding claims that press. A placeholder is drawn as DriftWM's stand-in and
  no longer carries a hint for this.
  DriftWM's defaults do claim it under the default super chord (`mod+left` pans
  anywhere), so out of the box there is no pointer way to dismiss a placeholder.
  `[mouse.anywhere]` with `"mod+left" = "none"`, or a `--super` chord other than
  `ctrl+alt`, frees the press.
- Screenshots: `Infinify msg screenshot` writes a PNG of the canvas as the
  compositor draws it, off-screen content included: the active view, one
  window, every window, or a rectangle, at any scale. No key is bound to it.
  See [Screenshots](#screenshots).
- Quit: the registered Control-Option-Escape hot key, a key bound to `quit`,
  `Infinify msg action quit` or SIGTERM. Each ends fullscreens, saves, closes
  the panels, stops capture and releases the hot keys, which returns the native
  desktop, and exits with status 0. If the exit chord cannot be registered a
  line on stderr says so and the other three remain. Return to desktop, the
  Quit button and Resize status went with the toolbar; the fixture modes keep
  them.
- A window resized natively, by its application or by hand on the desktop,
  keeps that size on the canvas: the next look at the window (an
  Accessibility report, or the reconciliation once a second) hands the
  controller its size, which becomes the window's size on the canvas with its
  top-left kept, and the scene is saved. Resizing a window by dragging its
  edge on the canvas uses the same readback transaction
  ([Resizing a window with the pointer](#resizing-a-window-with-the-pointer)).

A click on a source asks for native focus of that one window only: in a normal
run through the controller's focus request and the focus driver, which acts on
the window whose freshly validated identity matches the binding the controller
named; in the fixture modes by activating its owning application, as before.
With `--no-native-focus` the shell activates nothing on a click (what the
forwarded click makes the application do itself was not tried); without
Accessibility access no input is delivered at all. Identity validation checks PID, process birth, window number, current
owner PID, and the last observed native bounds immediately around delivery.
Private per-window routing is reused verbatim from
`../captured-windows/captured.m`, including its Cantrip signature provenance.
There is no global synthetic event fallback. Release-on-cleanup applies only to
the button this shell pressed in a source; user keyboard state is never
synthesized or released. While the app manages windows, a window that closes
leaves the canvas or leaves a stand-in ([Managed windows](#managed-windows));
in a manual run a lost or closed source becomes an inert placeholder, unless
`close-window` or `suspend-window` asked it to close in the ten seconds before.
Stream errors detach rather than leaving stale content eligible for input, in both.

## Managed windows

In DriftWM every toplevel is managed from the moment it exists. This is that
rule for native Mac windows: the app finds the ordinary windows itself, places
them, follows their titles and lets them go when they close. The decisions are
the controller's and are upstream's; [LIFECYCLE.md](../../crates/desktop/LIFECYCLE.md)
is the contract and lists every difference. **None of what this section says
about real windows has been run**: no test launch had Screen Recording access.
[What was run](#what-was-run-for-managed-windows) says what was.

**At launch.**

- With Screen Recording and Accessibility access: no chooser. The canvas opens
  at once on every display and the app starts managing.
- With either missing: the permission window of [Desktop mode](#desktop-mode),
  with an Allow… button for each, Relaunch and Quit; the canvas opens from it
  once both are there. The app still never asks macOS for a grant by itself.
  (Until 2026-10-10 the chooser came here, and Screen Recording alone opened
  the canvas.)
- `--windowed`: the canvas opens at launch in its one window, whatever is
  granted. With Screen Recording it manages windows; without, it manages
  nothing and says why on stderr: `Windows are not managed: Infinify has no
  Screen Recording access. A run without --windowed asks for it.` Access is
  read when the canvas opens and macOS applies a new grant at the next launch.
- `--manual`: the chooser comes first whatever the grants are, with its own
  Allow… button; only windows picked there are captured, nothing is adopted
  and no saved placeholder is dropped. A source that closes leaves a
  placeholder to rebind, except one that `close-window` or `suspend-window`
  asked to close: when it goes within ten seconds of the command it leaves
  nothing, or a stand-in, as in a managed run. With `--windowed` the canvas
  opens at launch and the chooser comes up above it.
- Never in `--source`, `--demo`, `--demo-probe`, `--demo-probe-guard` or the
  owned-resize modes, which also reject `--manual` (exit 64). A saved scene that
  failed to load suppresses it too.

**Which windows.** Real windows only, as DriftWM manages toplevels and their
dialogs and never a popup, a tooltip or a helper surface. The candidates are
what the chooser lists, restricted to what is on screen: normal-layer windows
of regular (Dock) applications other than Infinify, at least 40x40 points. Of
those, with Accessibility access, a window is adopted when its application
reports it as a standard window or a dialog (Accessibility subrole
`AXStandardWindow`, `AXDialog` or `AXSystemDialog`), whatever its size or
title. One reported as anything else (a floating panel, a sheet, which
belongs to its window, an unknown kind) is left on the desktop. Without
Accessibility access, for an application that does not answer, or for a
window its application does not list (it lists only the windows of the active
Space), every candidate is adopted except an untitled one smaller than
200x150, which is how a browser's 56x96 untitled helper stays off the
canvas. The test is made when a window comes on screen and never again: a
window already on the canvas stays for the session whatever it turns into. A
window of 200x150 or more that the test leaves out is named once on stderr
(`… not adopted: Accessibility reports it as AXUnknown, …`), since a borderless
application window can be one of them: only a `--manual` run's chooser can add
it by hand, though the line still ends "Choose windows adds it by hand".
**Every adopted window is captured** while it is in view on
some display, with no further question: a managed canvas shows whatever those
windows show. Use `--manual` to keep choosing window by window.

**Windows that are already open.** The first discovery pass reports each one
that is on screen, back to front. A window whose application and title match a
saved slot takes that slot back, with its logical id and world frame; failing a
title match it takes the lowest free slot of its application; otherwise it is
placed like a new window. The pass focuses none of them and moves no camera. A
window that exists but is not on screen (minimized, hidden, on another Space)
is not captured, but the pass names it by application and title, and the slot
with that application and title is kept for it: when the window comes on screen
it returns to its frame, and that adoption asks for no focus and moves no
camera either. Then the slots nothing matched are dropped,
**including placeholders an earlier build saved**, unless
`[session] restore_windows = true`, which keeps them as stand-ins. Stand-ins
are always kept. If the config file exists but was refused at launch, nothing
is dropped and nothing is made a stand-in in that pass: the defaults that are
in force do not speak for the file's `restore_windows`. This is the macOS form
of upstream's session rule: on Wayland quitting the compositor ends its
clients, here the applications outlive Infinify, so the scene file keeps one
slot per window and the running windows return to theirs.

That is the adoption alone. With Accessibility access
[native focus is followed](#native-focus-is-followed) in every normal run, and
an adopted window is on the canvas like any other: when it is the window the
frontmost application has focused, the next read of native focus takes it as an
activation. A read is made at the first poll after a window is adopted (the
polls are 80 ms apart), whenever a focus event is reported, and once a second
besides, or twice where the events are not in place
([Event-driven tracking](#event-driven-tracking)). It then replaces the saved focus, is raised
and heads the most-recently-focused order, and if it is clipped on the display
that shows its centre that display's camera flies to it, at 1:1 unless `[zoom]
reset_on_activation = false`, a camera that `[session] restore_camera` restored
included. Without Accessibility access nothing follows, and the saved focus and
the cameras stay as the pass left them.

The same pass runs again whenever the canvas is reopened after Return to
desktop: the windows return to their slots, and the slot of a window that
closed in between is dropped, or kept as a stand-in with `restore_windows`.

**A window that appears later** is offered once its frame has held still for
50 ms, from one look at the window list to a later one. The first look is made
when its application reports the window created, where
[the events are in place](#event-driven-tracking), and by the poll otherwise;
the later ones by the poll, which looks every 80 ms while a window is waiting.
Its size is the native window's. Its place
on the canvas is never where the native window sits on the desktop: it comes
from `window_placement`, `center` (the default: under the `focus_placement`
point, the centre of the view, of the display under the pointer), `cursor` or
`auto` (beside the focused window's cluster), stepped down the diagonal while it
would sit exactly on another window. It goes on top, takes the canvas's logical
focus, and the camera of that display flies to it, to 1:1 unless `[zoom]
reset_on_new_window = false`; under `cursor` placement the camera stays.

**A window that closes** leaves the canvas. With `[session] suspend_on_close =
true` (or a `[[window_rules]]` entry that sets it for that application) it
leaves a stand-in instead: a placeholder that keeps the id, the frame and the
place in the stack. The focus moves as upstream's does, to the window that
last had the canvas's focus among those docked to or overlapping the closed
one, else the last one still in view, else the nearest in view, else to none;
with `[navigation] auto_navigate_on_close` (on by default) the camera flies to
a docked or overlapping follower that is not wholly in view. A widget or a
screen-pinned window is never the follower, and one that closes has no docked
or overlapping follower
([Window rules](#window-rules-widgets-and-pinned-windows)). "Had the focus"
is the one most-recently-focused order of the canvas, the order Option-Tab
walks ([Window navigation and native focus](#window-navigation-and-native-focus)):
a click in the canvas, a new window, `msg focus` or a followed native focus
enters it once the real window's focus is confirmed, or at once when the app
performs no native focus (no Accessibility access, or `--no-native-focus`). A
drag in progress on another window goes on, and then no camera flies. A window counts as closed when its
window number is gone from the system's window list or its process is gone,
and, where [the events are in place](#event-driven-tracking), also when its
application has reported it destroyed and it is no longer on screen; a
capture stream that fails while the window is still there keeps the old
behaviour, a detached placeholder, which only a `--manual` run's chooser can
rebind ([Desktop mode](#limits-of-desktop-mode)).

**Titles** follow the native window and are saved, because slots are matched by
title at the next launch.

**Capture on demand.** A ScreenCaptureKit stream runs only while its window is
in view on some display. It stops about two seconds after the window left every
view and starts again when it returns; a window that returns within those two
seconds shows its last frame at once, and one that returns later shows its
last picture, which the compositor keeps ([Rendering](#rendering)), until the
restarted stream delivers.

**Capture rate.** A stream is asked for a frame at most once per refresh of
the fastest display a canvas panel is on, and at least 60 times a second
(`NSScreen.maximumFramesPerSecond`; it was 30): 120 a second on a ProMotion
display. ScreenCaptureKit delivers a frame only when the window's content
changed, so a still window costs what it did, none. A window that redraws
continuously (video, a game, a fast scroll) is now captured, uploaded and
composited up to four times as often as before, which is its share of GPU
and WindowServer time times four at most; every delivered frame redraws only
the outputs that show that window. The rate is read when a stream is started
or resized: after a display is added or removed, a running stream keeps the
rate it has until then.

**Closing, suspending and relaunching** are explicit actions only; nothing
closes a window by itself.

| Entry | A focused or selected live window | A stand-in or other placeholder |
| --- | --- | --- |
| ⌃⌥Q, `msg action close-window`, `msg close [APP_ID] [--id N]` | its close button is pressed; when it goes it leaves no stand-in, whatever `suspend_on_close` says | dismissed |
| `msg action suspend-window` | its close button is pressed; when it goes a stand-in stays | dismissed |
| `msg suspend [APP_ID] [--id N]` | focused first, then as `suspend-window` | `window is already suspended` |
| `msg relaunch [APP_ID] [--id N]` | `no suspended window matching selector` | its application is opened by bundle identifier; the next window of that application to appear within thirty seconds takes the slot. Asked again within those thirty seconds: `ok`, and nothing more happens |

The press goes through Accessibility to exactly the window the controller
named, after the identity checks the focus driver makes (process id, process
birth, window number, and that the controller still binds that window), once
before looking the window up and again immediately before pressing. Without
Accessibility access the status line says so and nothing is pressed. The window
stays on the canvas until it has really gone, so an application that asks about
unsaved changes keeps its window. The command is remembered for ten seconds, as
upstream remembers it: a window that goes later than that, because the
application asked first or because nothing was pressed, leaves what
`suspend_on_close` says. An application that is not installed gives a
status note and a line on stderr (`Relaunch failed: no application with bundle
identifier "…" is installed`).

**Known limits**, from reading the code:

- Only windows on screen are captured. A window that is minimized, hidden or on
  another Space during a discovery pass keeps its saved slot only if it has a
  title and the slot has that same title. One without a title, or retitled
  while Infinify was not looking, loses its slot (kept as a stand-in with
  `restore_windows`) and is placed as a new window when it comes on screen. A
  slot kept this way whose window then closes without ever coming on screen
  stays a placeholder until the next pass. A window with no saved slot is
  placed, focused and flown to when it first comes on screen, like any new
  window. A native tab is a window of its own that is on screen only while
  selected, so each tab selected while the app is managing becomes a canvas
  window.
- Slots are matched one window at a time, in the order the windows are
  reported. Of two windows of one application whose titles changed while
  Infinify was not running, each takes the lowest free slot, and one that kept
  its title can find its slot taken by a retitled sibling reported before it:
  the two then sit in each other's frames.
- An application that hides a window on close instead of destroying it keeps
  its window number, so that window stays on the canvas, unless the
  application also reports the window destroyed through Accessibility, which
  [the events](#event-driven-tracking) now take as a close once the window is
  off screen. Whether such applications report that has not been seen.
- ⌃⌥Q acts on the canvas's logical focus: the window last clicked in the
  canvas, the newest window, the one `msg focus` named or a navigation chose,
  or, with Accessibility access, the canvas window last focused in its own
  application (Command-Tab, the Dock), which the canvas follows
  ([Native focus is followed](#native-focus-is-followed)).
  Without that access, or with `--no-native-focus`, a focus change outside the
  canvas is not followed. Look at which window the canvas has focused before
  pressing it. With `--windowed` no hot key exists; use `msg`.
- The focus request that comes with a new window, or with the window that
  takes the focus after a close, goes to the same coordinator as every other
  focus request: with Accessibility access the real window is activated and
  raised, without it the request is answered as logical focus. For a new window
  that asks for what macOS has usually just done itself. Neither has been run
  with a real window.
- Who takes the focus after a close is read from the most-recently-focused
  order, with its limit: where native focus is allowed, a window whose focus
  request failed or was overtaken before it was confirmed is not in that order,
  so it is not preferred as the follower, where upstream would have gone back
  to it.
- A stand-in is drawn as upstream draws one, bar, body and name label
  ([Rendering](#rendering)), and so is every other detached placeholder; the
  two cannot be told apart by eye. Neither a click nor Return relaunches it as
  upstream's do. A click focuses it like any window, and ⌃⌥Q then dismisses
  it; it is relaunched through `msg relaunch`.
- A close or suspend request is forgotten after 10 seconds and a relaunch after
  30, as upstream forgets them, measured on the clock the app ticks every
  80 ms while the canvas is open. Within its 30 seconds a pending relaunch
  takes the next window of that application whatever its title; upstream
  narrows that to 5 seconds with an activation token macOS does not have.
  Opening an application that is already running with other windows makes no
  window, so such a relaunch simply lapses. `msg relaunch` answers `ok` for an
  application that is not installed, where upstream answers `<name> is no
  longer installed`.
- The limits of the first pass: a window that is off screen without a matching
  title, still being moved after the two-second wait, or missing from both
  reads of the shareable windows loses its slot and is placed afresh when it is
  next offered. (Until 2026-10-10 a canvas could be closed by Return to desktop
  and reopened, and a window opened in between was then treated as new. A
  normal run opens its canvas once now.)
- A window whose capture failed, or that the controller refused, is not offered
  again until it has left the screen and come back, or the canvas is reopened.
  Until then another window of that application with a different title can
  take its waiting slot.
- If a read of the shareable windows fails it is tried again about every two
  seconds while Screen Recording access stands (two to three once the first
  pass has ended and [the events are in place](#event-driven-tracking), because
  the pass that retries then runs once a second), and the status line says so
  each time (stderr once per reason).
  Until one succeeds the first pass does not complete: nothing is dropped and
  later windows are neither focused nor flown to as new windows are (followed
  native focus aside).
- With a config file that was refused at launch, no slot is dropped or made a
  stand-in until a discovery pass runs with an accepted config: fix the file
  and reopen the canvas, or relaunch.
- Every look at a managed window makes one window-list query and one
  controller call. Without the events every window is looked at on every poll
  (80 ms), as before; with them, all of them once a second and each when an
  event names it or its application ([Event-driven tracking](#event-driven-tracking)).
  With very many windows neither has been measured.
- A press that Accessibility does not answer in time is treated as sent, so an
  application that does not respond gives no status note.

### Managing only named processes

`--only-pid PID[,PID…]` (the flag may repeat) gives a windowed run a scope:
the windows of those processes are managed and no others. It exists so that
the managed product (adoption, native focus, click forwarding, the window's
end) can be run on disposable windows by a test, also from a shell that has
Accessibility but no Screen Recording access, without the run ever touching a
window that is not the test's. With no `--only-pid` nothing differs: in
particular a run without Screen Recording access still manages nothing.

- A process is in scope by its pid and its start time, read once at launch.
  A process that ended and whose pid another took since is not in scope.
- Refused with exit status 64 and one line on stderr, before anything opens:
  a value that is not a list of process ids, a process that is not running or
  is not this user's, Infinify itself, a process named twice, a launch without
  `--windowed` or without `--state`, and `--manual` or a demo mode beside it. Without
  `--windowed` a launch that lacks a grant goes to the onboarding window; the
  chooser attaches whatever is picked in it. The sizing actions, `msg resize`, a rule's size and
  fullscreen need no flag and run in a scope like everything else: a size
  effect names the process of a source that was bound here, so no process
  outside the scope can be asked for a size
  (`tests/e2e/scoped-sizing.sh`). Without `--state` the run would settle adoption on the
  default scene with only its own windows present, and every saved slot of a
  real window would be dropped or made a stand-in and saved so.
- The window manager considers a window of any other process no candidate at
  all: it is not timed, not asked about through Accessibility, not read, not
  offered, not named as present, and no Accessibility observer is put on its
  application (`window-manager.m` `-pass:`, `window-events.m` `-add:`).
- The one place a native window is bound, `-attach:logical:world:placed:` in
  `main.m`, refuses a process outside the scope before a source, a router or a
  controller source exists. Native focus, a forwarded press or motion, close
  and the resize paths all act on a bound source or on the identity the
  controller was given with it, so none of them has a window outside the
  scope to act on. No check was added at those actors.
- With Screen Recording access the scope's windows are captured as in any
  managed run. Without it the shareable windows are never asked for, so
  nothing can prompt: a candidate's frame comes from the window list, its
  title from Accessibility, its application's name and bundle identifier from
  the running application. The window is bound, focused and clicked like any
  other; no stream is started for it and its tile has no picture (the frame
  and what the renderer draws for a window that has not delivered one). Its
  title follows only where the window list gives one, which without Screen
  Recording access it did not for the one window looked at.
- A scoped run without Screen Recording access names no window that is off
  screen, so a saved slot is not kept waiting for a minimized or hidden window
  of a scoped process: it is dropped or made a stand-in as for a closed one.
- What the scope does not contain: the `launch`, `exec` and `warp_pointer`
  effects and `autostart` act on no bound window, and `msg relaunch` or a
  click on a stand-in launches the stand-in's application whatever the scope.
  A test keeps them off with its own empty `--config` and a `--state` that
  holds no stand-in. Read-only Accessibility is still
  sent to the frontmost application, whichever it is, to read which window
  has native focus, as in any windowed run.
- A scoped window that is on screen when Infinify starts is adopted as one
  that was already open, neither focused nor revealed. One that appears later
  is a new window and gets the focus, natively too: start the fixtures first.

`--debug-pointer`, which is refused without `--only-pid`, serves one more
request on the IPC socket, for a test that may not move the pointer:

```json
{"DebugPointer":{"phase":"probe","window":1,"at":[0.5,0.5]}}
{"DebugPointer":{"phase":"down","window":1,"at":[0.83,0.5],"button":"right","modifiers":["alt"]}}
{"DebugPointer":{"phase":"drag","to":[40,0]}}
{"DebugPointer":{"phase":"up"}}
```

`phase` is `probe`, `down`, `drag` or `up`, `window` the id `msg state` gives,
and `at` the point as a fraction of the window's placement on its output. The
reply is `{"Ok":{"DebugPointer":{"screen":[x,y],"screen_rect":…,"clip_rect":…,"hit":ID,"border":EDGE}}}`
or `{"Err":"…"}`: a point that is clipped, off the panel or under another
window is refused, never moved.

- `down` takes `button` (`left`, `right` or `middle`; left when absent),
  `modifiers` (any of `alt`, `shift`, `ctrl`, `super`) and `offset`
  (`[ox, oy]` screen points added to the point), which is how a point of the
  [resize border](#resizing-a-window-with-the-pointer) just outside a frame is
  named; the controller must then say that the point is that window's border.
- `drag` needs a press that is down. Its point is where the press went down
  plus `to` screen points, since a fraction of a tile that is changing size
  names no steady point, and it must be on the canvas panel.
- `up` with `window` and `at` releases at that fraction of the placement as it
  is now; without them it releases where the press last was, which is how a
  drag ends and the only way to release over a window that has closed.

Each makes a mouse event of the matching type and hands it to the canvas
view's own `-mouseDown:`, `-mouseDragged:` and `-mouseUp:` (the right and
middle buttons' handlers for those), so the binding lookup, the controller's
focus request, the hold for native focus, the forward to the window, a window
drag, a resize grab with every size it asks and the release run as for a
person's press, drag and release. Those handlers read the event's button
number, modifiers, location and time. `+[NSEvent mouseEventWithType:…]`
numbers every event it makes 0, a right-button one too, so for the right and
middle buttons the event's own Quartz event is copied, given the number its
type means, and made an `NSEvent` again; the trace line
`debug: pointer down button=1 trigger=right binding=resize_window` shows what
the handler then read. Nothing is posted to the session and the pointer stays
where it is. What it does not exercise is the window server delivering a
click or a modified right-button drag to the panel. A press that is not
released within five seconds of its last event is released where it last was,
with its own button. Without the flag the line reaches the controller, which
refuses it as an invalid request.

`INFINIFY_DEBUG=1` in the environment, in any run that draws the canvas,
prints one line on stderr every two seconds while the canvas is open, every
rate a second:

```
frames: 2.00s display=120 redraws=491.5 flushes=118.0 drawn=118.0 presented=118.0 flush_ms=0.13/0.36 main_gap_ms=14.0 sources #1=120.0/120.0/0.0 #2=120.0/120.0/0.0
```

`display` is the refresh rate the frame timer follows; `redraws` the changes
that asked for the scene to be drawn (a window's picture, an animation's
step, a decoded chunk, a description); `flushes` the times the scene was
gone through with something to draw; `drawn` the frames handed to the
display and `presented` those it showed; `flush_ms` how long one flush kept
the main thread, mean and worst; `main_gap_ms` the longest the main thread
went without returning to its run loop; and for each bound window the frames
its stream delivered, those kept, and those passed over because they said
nothing had changed. Without the variable nothing is timed or observed and
the renderer counts nothing; each window's three counters are added to and
never read.

`INFINIFY_DEBUG_SYNTH=RATE` beside `--only-pid`, and in no other run, feeds
every bound window RATE made-up frames a second (240 at most) in place of
the capture such a run may not have: IOSurface-backed 32BGRA buffers of the
window's own pixel size, a band moving down each, made on a background queue
and handed to the main queue where a stream's frames arrive. It makes no
frame while two are waiting to be taken, as a stream stops at its queue
depth, and ends with the window's binding. Synthetic sources start no real
capture streams, so the workload is the same with or without Screen Recording
access. The earlier measurements below predate that separation.

`tests/e2e/scoped-render-bench.sh --live-owned-fixture` measures with the two: four fixture
windows of 1700x1100 points of content, 1700x1132 with the title bar
(3400x2264 pixels each), a canvas over the whole
visible screen, 120 frames a second into each, all four tiles in view at
zoom 0.54, ten seconds at rest and ten while a camera target is sent through
the socket at about 110 a second. On the 120 Hz built-in display, 2026-10-11,
the build before the [frame pacing](#rendering) change and the one after it,
one run of each (the build after is the tree as it landed, after review):

| per second | at rest, before | at rest, after | panning, before | panning, after |
|---|---|---|---|---|
| flushes | 239.0 | 119.0 | 302.9 | 119.2 |
| frames drawn | 239.0 | 119.0 | 238.5 | 119.2 |
| frames presented | 120.0 | 119.0 | 119.1 | 119.2 |
| one flush, mean / worst, ms | 3.27 / 7.84 | 0.14 / 0.37 | 2.76 / 21.75 | 0.23 / 8.69 |
| worst main-thread gap, ms | 13.5 | 15.2 | 22.3 | 13.4 |

It asserts that each window kept at least 90% of its frames, that flushes do
not exceed the display's rate by more than 3%, that frames presented are
within 10% of it, and that the main thread was never away for 50 ms. The
build before failed the second in both phases and held the others: the
display was already given a frame for every refresh, and what the change
removed is the second draw of each refresh and the wait in every draw, from
about 780 ms of main-thread time a second to about 20.

- The pictures are made up. What ScreenCaptureKit and the window server
  spend to capture four real windows of that size, and what the windows'
  own applications spend drawing under the canvas, is not in these numbers;
  nor is a display that is not the built-in one. The owner's desktop run
  with real windows has not been measured: `INFINIFY_DEBUG=1` on that run
  prints the same line.
- About once a second the main thread was away for 13 ms or more in both
  builds, longer than one 8.3 ms refresh, and the build that draws only on
  the display link's callback lost that callback and showed 118 or 119
  frames a second. A sample of the benchmark's own instance found it: the
  window tracker's reconciliation asked every running application what it
  was, one synchronous LaunchServices round trip each, about a hundred a
  second (35 of the 54 ms sampled in `-[DWWindowEvents add:]` were that
  wait). The look is now made off the main thread and only an application
  not yet observed is asked again; one that ended is found from the process
  table. Five runs since: 119.9 to 120.0 frames presented a second in both
  phases, the main thread never away for more than 6.1 ms at rest and 11 ms
  while the test pans through the socket.
- A flush of 9 to 21 ms was seen after the change about once in every other
  run (8.69 ms in the one tabulated); every other flush was under 1.2 ms.
  Not explained. One run of six, the first after a build, held every flush
  for 5 to 7 ms from start to end (the main thread waiting for a drawable
  each refresh, the picture still at 120 a second); the five after it did
  not. Not explained either: a queue of drawables that fills and stays full
  when frames are made exactly as fast as they are shown is the likely
  shape, and nothing bounds it yet.

`tests/e2e/scoped-windows.sh` is the test. It builds
`native/fixture/scope-fixture.m` (a regular application with one titled
window holding an `NSButton`, a plain view that takes no first click and a
`WKWebView`, which reports to a file what reached it), starts three, names two
to `--only-pid`, and presses and releases on their tiles. With
`INFINIFY_E2E_ELECTRON` naming a generic Electron binary it adds the window
of `tests/e2e/scoped-electron`. It takes the foreground from the application
that has it and holds it until the fixtures exit, when macOS returns it.

- A click is judged by what the fixture was as it handled each event (active,
  key, main), which the fixture records with the event. A fixture that is no
  longer active when read afterwards lost the foreground to another
  application: the test prints `DISTURBED` with the frontmost pid and does not
  fail the click for it.
- Each native fixture is asked to put its window directly under the canvas
  panel, and the Electron one directly over the first of them, before
  "visible to the window server" and the animation frames are measured, so
  that a window of another application that had come between them and the
  canvas is no longer over them. While one still lies over a fixture (it is
  over the canvas too), those two assertions are skipped for that fixture and
  `SKIPPED` is printed.
- Exit status: 0 with `PASS` only when nothing was skipped or disturbed; 3
  with `INCOMPLETE … NOT CHECKED: …` when nothing failed but something was; 1
  on a failure.
- The usage errors are run before any fixture exists, each bounded to two
  seconds and killed and failed if it has not exited, with a home directory
  of the test's own.
- Infinify is started only once every fixture reports its window shown.

Run on 2026-10-11 (macOS 27.2, Apple Silicon) from a shell with Accessibility
and without Screen Recording access, with the Electron window (Electron 33):
twice, each time 78 `ok` lines, nothing skipped or disturbed, `PASS` and exit
status 0. The figures are the first run's; the second's were 36, 1, 43, 24
and 40 (Electron) ms, 60 and 116 frames.

- The seven usage errors each exit 64 with their line and no socket, the one
  without `--state` among them (`Infinify: --only-pid needs --state`).
- `msg state` lists exactly the scope's windows, still there and not
  suspended three seconds later; stderr has `Managing only the windows of
  --only-pid … No Screen Recording access: their tiles have no picture.`
- Before any click no native focus was requested, each scoped fixture lay
  whole under the canvas panel, before and after it was put directly under
  it, was visible to the window server and ran 60 animation frames a second
  (the Electron page 122), and none was active.
- A click on the web view of an inactive fixture: the press was held
  (`focus_pending=1`), native focus was answered `focused`, the press went 49
  ms after it was made, and the page counted one `mousedown`, one `mouseup`
  and one `click` at the point aimed at, the fixture active, key and main as
  it handled each. The same click again, with nothing waited for in between
  but the 0.3 s in which a second copy of the first would show, went after 1
  ms (`focus_pending=0`) and the counts were two.
- A click on the plain view of the other, inactive fixture, released at once:
  the release was held behind the press (`released=1`), both arrived once, at
  the point aimed at, and the first fixture took nothing.
- A click on the `NSButton` of the fixture that was inactive again ran its
  action once.
- A press on the plain view that the test never released: no release in its
  first three seconds, one release where it went down 5.03 s after the press,
  and a `DebugPointer` release after that refused (`no DebugPointer press is
  down`).
- A click on the Electron page, inactive: held, focused, sent after 31 ms,
  one of each event at the point aimed at, the application active and its
  window focused as it handled each.
- The fixture left out of the scope, a regular application's window on
  screen under the canvas, took no event and was never activated; every pid
  in the `debug:` lines was one of the scope's.
- An unscoped run afterwards printed `Windows are not managed: Infinify has
  no Screen Recording access. A run without --windowed asks for it.`, had no
  windows, answered `DebugPointer` with an error and left every fixture's
  counts as they were.

Earlier the same day, before the fixtures recorded their state with each
event and before they were put directly under the canvas: one run failed at
the `NSButton` click because the fixture, active when its action ran (the
trace had `outcome=focused` and `delivered after 32 ms`), was no longer
active 0.3 s later, no fixture of the test having been activated since; and
several runs skipped "visible and drawing" for all three scoped fixtures under
a 1835x1290 window of another application. Whether the placing under the
canvas removes that skip was not seen: in the runs since, no such window lay
over the fixtures when they were measured.

An Electron window that another opaque window covers whole stops its
animation frames; under the canvas alone it does not.

Found while the test was written, and since traced and changed: **two
windows that appear together after Infinify has started.** Each gets the
focus a new window gets, and the second request withdraws the first after
the first has asked for its application. The focus lease allowed only the
application that was in front at its own intent, so the second request was
refused as soon as the first one's application arrived, and neither window
was focused (`guard_denied`, both). A lease now also allows the
applications that the requests it followed within two seconds were for:
that change of foreground is this run's own doing. `tests/e2e/scoped-sizing.sh`
shows two fixtures at once (case 23): the withdrawn request may end refused,
the last one ends focused, and the window the canvas holds focused is the
one in front.

Not run: a scoped run with Screen Recording access (capture, the retitle,
and the scope filter on the windows named as present), which this shell
cannot have; a pid taken over by another process during a run; hover
forwarding, close and suspend under a scope (the test runs with
`--no-hover-forwarding`); a person's own click on a scoped tile; `msg
relaunch` under a scope. The refusal of `--only-pid` without `--windowed`
was run once by hand (exit 64, `Infinify: --only-pid needs --windowed`) and
is not in the test, which never starts Infinify without `--windowed`.

### Capture and rendering performance

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
or image content. The default benchmark leaves this diagnostic disabled.

`INFINIFY_BENCH_REPORT_MS=500` changes only the capture fixture's periodic
status reports to every tenth existing 50 ms tick. The watchdog, command checks,
event reports and animation timer keep their existing cadence; the default is
50 ms. This is a separately labeled measurement diagnostic, not a product setting.

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
Synchronous compositor probes retain their existing path. Continuous camera
commands and scroll gestures mark the scene for a coalesced save. Configured
desktop runs copy the controller on main and serialize, atomically replace and
sync the file on a serial worker. One save may run while one pending copy waits;
a newer pending copy replaces the obsolete one. Shutdown drains earlier saves
before its final synchronous save. Standalone probes retain synchronous saves.
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

The explicitly scoped benchmark can instead select a single
`CAMetalDisplayLink` offer clock with `INFINIFY_BENCH_METAL_CLOCK=1`. Its delegate
advances the scene once and consumes the offered drawable at most once, without
another acquisition queue. Commands are committed before `present()` under
[Apple's offered-drawable contract](https://developer.apple.com/documentation/quartzcore/cametaldisplaylinkdelegate/metaldisplaylink(_:needsupdate:)).
A screen link advances the controller if offers stop during occlusion or sleep;
it does not acquire pixels for that covered output. `metal_clock:` reports
offered, unused and fallback callbacks, plus actual present-call deadline misses.
The timed screen clock remains the production default;
`INFINIFY_BENCH_SCREEN_CLOCK=1` explicitly selects it for the same-build comparison.
`INFINIFY_BENCH_CV_CLOCK=1` selects a separate scoped Core Video display-thread
candidate using the timed drawable pool. Its callback publishes only a valid
Mach-clock target and period to at most one pending main-queue tick; newer
callbacks replace that target, and repeated targets are rejected. Scene and
layer work stays on main. Cancellation prevents queued callbacks from drawing,
then stops and releases the link; a quiet link retains the ordinary screen
fallback. `display_thread:` separates source callback cadence/gaps from delivered,
coalesced, stale and invalid ticks and original-pending/latest-target queue age.
[Core Video's display link](https://developer.apple.com/documentation/CoreVideo/cvdisplaylink-k0k)
is deprecated, so this candidate stays explicitly scoped. A requested frame rate
is [best effort](https://developer.apple.com/documentation/quartzcore/cadisplaylink/preferredframeraterange),
and none of these callback counters establish optical native-window cadence.

`INFINIFY_DEBUG=1` reports distinct measurements: screen-link callback cadence,
source delivery/acceptance, encoded draws, and actual drawable presentation.
`presentation:` uses each drawable's positive `presentedTime`, sorting samples
to calculate mean/p99/worst gaps, missed refreshes, command-submission latency
and GPU time. It also reports the age of the last observed presentation, so a
window with no newer timestamps cannot look healthy from its earlier short gaps.
Camera updates/repeats compare the camera and zoom actually used
to encode consecutive displayed frames. New source buffers or an animated
background do not count as new camera steps. Submission latency is not input or
capture freshness, and accepted source buffers may repeat content. `drawable:`
separately reports time inside asynchronous `nextDrawable`, worker queue delay,
ready-set publication time, notification delay back to main, and command
submission to GPU completion. A
short GPU execution time alone cannot exclude a scheduling or acquisition stall.
Handlers that return a zero presentation time are counted separately from positive
timestamps. Duplicate positive timestamps and callbacks older than the preceding
batch are reported separately; they cannot manufacture distinct display intervals.
Missing callbacks cannot establish zero physical display updates.

The benchmark is read-only without `--live-owned-fixture`. Its scoped canvas
uses floating level, takes no pointer input and requests no native focus. It
reports actual visibility rather than assuming this level keeps it unoccluded.
Read-only on-screen window ordering and rectangle coverage are sampled outside
the selected timing windows; coverage alone does not establish an opaque region.
During native timing windows, the harness also reads only its own canvas's
screen rectangle, untransformed bounds and transform at 10 Hz. This distinguishes
WindowServer composition motion from changes to the canvas's own geometry.
Native mode
places only its own cooperative host's four 320×232-point windows above its own
canvas. It independently samples WindowServer rectangles and checks exact
transform, alpha and bounds restoration before removing the host on every exit.
Those rectangle reads show geometry updates, not optical presentation of native
windows. Native helper submitted/written/applied/superseded/dropped counter deltas
are read outside the selected timing windows; they establish delivery, not native
optical frame rate. Synthetic and capture modes use four 1700×1132-point fixtures;
`buffers:` reports retained CVPixelBuffer dimensions and `capture:` a change.

```sh
# Short strict sample: actual 120 Hz presentation, including camera motion.
INFINIFY_BENCH_STRICT=1 INFINIFY_BENCH_SECONDS=4 \
  ./tests/e2e/scoped-render-bench.sh --live-owned-fixture
# Native background presentation, independent window movement and restoration.
INFINIFY_BENCH_MODE=native INFINIFY_BENCH_STRICT=1 INFINIFY_BENCH_SECONDS=4 \
  INFINIFY_BENCH_ZOOM_MOTION=1 ./tests/e2e/scoped-render-bench.sh --live-owned-fixture
# Slower capture content with a background that keeps changing each refresh.
INFINIFY_BENCH_MODE=capture INFINIFY_BENCH_RATE=60 INFINIFY_BENCH_ZOOM=0.21 \
  INFINIFY_BENCH_ANIMATION=1 INFINIFY_BENCH_STRICT=1 INFINIFY_BENCH_SECONDS=4 \
  ./tests/e2e/scoped-render-bench.sh --live-owned-fixture
# Separate capture-quality check: overview pixels, zoom-in quality and export.
INFINIFY_BENCH_MODE=capture INFINIFY_BENCH_RATE=60 INFINIFY_BENCH_ZOOM=0.21 \
  INFINIFY_BENCH_VALIDATE_BUDGET=1 ./tests/e2e/scoped-render-bench.sh --live-owned-fixture
```

Strict mode requires a visible, unoccluded canvas, at least 99% of requested
display refreshes, zero missed refreshes, no gap or presentation silence above
1.5 refresh intervals, no GPU errors or lost samples, and distinct ordered
positive presentation timestamps. Every displayed pan/zoom frame must also have
a changed camera pose, with zero repeated poses.
An average near 120 or the historical 90% smoke threshold cannot establish
stable 120. `INFINIFY_BENCH_SECONDS` selects whole two-second windows per phase
(minimum four seconds); `INFINIFY_BENCH_ZOOM_MOTION=1` adds continuous zoom.

An earlier capture-budget comparison on 2026-10-11, arm64 macOS 27.2, one 120 Hz
Retina display, used ten seconds per phase and the same build for both paths.
The baseline switches enabled full 2x capture and synchronous drawable acquisition.

| Metric | Full capture, synchronous acquisition | Adaptive capture, private acquisition |
|---|---:|---:|
| Pixels per captured window at zoom 0.21 | 3400×2264 | 850×566 |
| Capture pixel area | 100% | 6.25% |
| Main-thread flush mean, at rest | 15.93 ms | 0.12 ms |
| Main-thread flush mean, panning | 15.19 ms | 0.07 ms |

That run also observed full-size frames after zoom-in and for the exported
window, a valid PNG, unchanged world/native bounds and the overview budget after
export. Independently decoded PNGs recovered 64 alternating samples from a
one-point black/white marker that an upscaled overview raster cannot preserve.
The marker is enabled after timing measurements.

The subsequent four-second synthetic 120 Hz sample displayed 119.75 frames/s at
rest and 119.5 while panning, with one and two missed refreshes respectively,
a 16.667 ms worst presentation gap and a 9.3 ms worst main-loop gap. All 478
shown pan frames had a changed camera; no repeated camera step was counted as
motion. Strict mode failed, so stable 120 remains an active target. Earlier layer-bound
CAMetalDisplayLink acquisition trials displayed fewer frames and increased submission
latency; that separate-clock implementation was removed. Real captured fixture updates settled
near 60/s even when 120 was requested, and those runs also displayed near 60/s
despite an animated background and roughly 120 callbacks/draws. These are scoped
fixture observations, not measurements of total WindowServer CPU, an owner's
application workload, multiple physical displays or third-party native compositing.

An earlier default-alpha native sample used four seconds each of idle animation,
pan and continuous zoom on that display. The canvas was reported visible and
unoccluded throughout. Pan and zoom each had 480 presented frames with a changed
camera, zero repeated camera steps, zero missed refreshes and an 8.333 ms worst
presentation gap. Idle animation averaged 119.2 presented frames/s with three
missed refreshes and a 25 ms worst gap, so the strict target still failed. Ready
publication took at most 0.008 ms even while its main notification waited 6.311 ms;
the idle main-loop worst gap was 7.5 ms. Independent geometry reads and final
persisted-camera comparison passed, followed by exact original native transform,
alpha and bounds restoration.

Longer twenty-second samples subsequently reported occlusion during native
idle/pan and synthetic idle/early pan, despite the floating benchmark canvas.
The visible twenty-second synthetic zoom interval displayed 2399 frames with
2399 changed camera poses, no repeated pose and one missed refresh with a
16.667 ms worst gap. Its main-loop worst gap was 8.9 ms. This also fails the
strict target. The occluded intervals produced zero-time drawable callbacks and
long presentation silence; their encoded-frame rates cannot stand in for
physical presentation.

Read-only geometry diagnostics then found the canvas outside the active Space
and its screen position changing even while the scene camera and helper records
were idle. Native canvases now remain visible on deactivation and use
`CanJoinAllSpaces | Stationary`, with no AppKit window animation. The scoped
benchmark also creates its disposable host windows with that initial Space
behavior. Product alpha and opaque-region declarations remain unchanged.

The subsequent controlled native sample used twenty seconds each of idle
animation, pan and continuous zoom. All thirty timing windows reported a visible,
unoccluded canvas on the active Space, with alpha 1; independent idle geometry
remained unchanged. Pan and zoom each displayed 2400 frames with 2400 changed
camera poses, zero repeated poses, zero missed refreshes and an 8.334 ms worst
gap. Idle displayed 2398 frames, missed two refreshes and had a 16.667 ms worst
gap, so strict mode still failed. Main-loop work stayed within 3.3 ms across the
sample, while one idle drawable acquisition took 23.798 ms. Publication took
at most 0.008 ms, and GPU completion stayed within 7.139 ms. These observations
identify the presentation/acquisition pipeline as the next comparison; they do
not establish an absolute 120 FPS guarantee. Final camera persistence and exact
original transform, alpha and bounds restoration passed.

A subsequent eight-second-per-phase direct-offer clock sample kept the canvas
visible, unoccluded and independently stationary throughout. Pan and zoom each
displayed 960 distinct positive timestamps with 960 fresh camera poses and zero
misses. Idle displayed 956 frames, missed four refreshes and had a 25 ms worst
gap, with three zero-time presentation callbacks. Every measured present call
met the offered deadline, and no fallback or unused offers occurred. Submission
latency was about 41.4 ms, versus about 32.6 ms during the same-build timed
pan/zoom comparison. Its idle comparison was confounded by WindowServer moving
the canvas's screen rectangle while its own bounds and transform remained fixed,
followed by output/panel recreation. The direct-offer clock therefore remains
a scoped diagnostic and does not establish stable 120. Both runs persisted the
final camera and restored original fixture geometry and alpha exactly.

The thirty-second-per-phase optimized native sample after adding the frame
activity and physical-display guard retained the same canvas window, with its
own bounds and transform fixed throughout. Its screen rectangle nevertheless
moved or scaled 129, 28 and 18 times during idle, pan and zoom respectively.
Idle displayed 3567 positive timestamps with 32 missed refreshes and a 50 ms
worst gap; pan displayed 3544 fresh camera poses with 56 misses and a 175 ms
worst gap; zoom displayed 3575 fresh poses with 25 misses and a 150 ms worst
gap. Three idle observations were occluded. No duplicate/reordered timestamps,
repeated motion poses, GPU errors or acquisition timeouts occurred. This strict
failure, with external composition motion during every phase, does not establish
a cadence improvement from the activity token. Final camera persistence and
exact native transform, alpha and bounds restoration passed.

The subsequent stationary eight-second offer-clock sample tried a one-frame
latency preference. Idle again displayed 956 positive timestamps with four
missed refreshes, a 25 ms worst gap and three zero-time callbacks; pan and zoom
each displayed 960 distinct timestamps and fresh camera poses with no misses.
All canvas observations were visible/unoccluded, its own geometry stayed fixed,
and the owned native window stayed still during idle. Every present call met
the offered deadline, but one offer interval slowed to 60 Hz despite the 120 Hz
request. Submission latency remained about 41.4 ms. The preference did not
improve latency or idle gaps, so it was reverted; the timed path remains the
production default. Exact restoration and final camera persistence passed.

The subsequent eight-second display-thread clock sample delivered 120 source
callbacks/s without stale or coalesced ticks in the judged windows. The canvas
was visible, unoccluded and independently stationary throughout. Pan and zoom
each displayed 960 distinct positive timestamps and fresh camera poses with no
misses. Idle displayed 957 frames, missed three refreshes and had a 16.667 ms
worst gap. Its longest drawable acquisition took 24.549 ms, while main work
stayed within 3.2 ms and GPU completion within 7.627 ms. No zero-time callbacks,
duplicate/reordered timestamps or GPU errors occurred in those windows. The
separate callback thread did not remove idle acquisition stalls, so production
still uses the timed screen clock. Exact restoration and final camera
persistence passed.

An eight-second comparison then reduced the private pool to one ready drawable.
Idle displayed 947 positive timestamps with twelve missed refreshes and a
41.667 ms worst gap; pan displayed 919 fresh camera poses with four misses and
312.535 ms presentation silence; zoom displayed 960 fresh poses with no misses.
The canvas's own bounds and transform remained fixed, but its screen rectangle
changed ten times during idle and seventeen times during pan, with one occluded
pan observation. This did not establish a pool improvement, so the existing
two-ready limit was restored. Exact fixture restoration and final camera
persistence passed. Render-ahead remained a proposal and was not implemented;
performance experiments ended at the owner's request. Stable 120 FPS remains
unproved.

Some native launches reported the canvas occluded and drawables
returned zero presentation timestamps. Neither a scene alpha of 0.999 nor an
initial AppKit alpha of 0.999 reliably removed that behavior. A non-opaque owned
host also failed to remove it in the longer sample; product opacity and opaque
regions were left unchanged. The harness reports panel visibility separately and refuses
a strict success when it observes an occluded canvas. Its optional six-second
idle diagnostic compares scene camera/zoom with independent transform, rectangle,
alpha and untransformed-bound ranges. These short samples establish compositor
cadence only; native-window geometry and restoration do not establish optical
native-window FPS or usable third-party compositing.

### Native presentation through a cooperative helper

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

`python3 tests/e2e/scoped-native-group.py --live-owned-fixture` passed on
2026-10-11 with two newly spawned fixture processes and separate cooperative
helpers. Each helper received only its own window's records; independent
WindowServer reads checked both transforms through pan and zoom, with native
bounds unchanged. Ending one helper restored the surviving window's exact
original transform, alpha and bounds while the canvas IPC remained responsive.
Children were removed on exit. Evidence:
`target/ipc/group.xqf7vc6p/result.json`. This establishes scoped routing and
recovery, not third-party compositing, cross-application drag/drop or optical
synchronization.

The canvas panel sits behind native windows and draws the background, stand-ins
and canvas overlays. A root visible on several displays keeps one real native
placement; additional placements use a shared live capture with each output's
camera, zoom and clip. The protocol v2 client sends the selected placements as transforms
and alpha values. Windows outside every output are parked beyond the union of
the physical displays. Native bounds are read independently of the transform,
so camera movement does not change world geometry, focus bounds or resize
readback. A helper frame limit is enforced before submission: exceeding it ends
presentation and restores the windows instead of silently omitting some.

The owner selected **one independent view per display** on 2026-10-11, replacing
the earlier continuous-view answer. `native-views.m` keeps a root's real placement
on its existing output while visible, then chooses the largest remaining visible
placement. It forgets that choice when the source identity changes. The other
placements share one on-demand ScreenCaptureKit stream per root; no duplicate
stream is created for each display. Capture demand uses only these extra views,
keeps the existing two-second idle grace and bounded recovery, and never asks for
a permission grant. Without Screen Recording access the native placement still
works, but additional views have no pixels. Capture errors retain the native
binding. A session departure stops these streams and clears their saved pixels;
reconnection obtains fresh shareable-window identities.

Replica mouse, scroll and hover delivery uses the existing scoped per-window
posting mechanism. `native-replica-input.m` rechecks process birth, window owner
and untransformed bounds, and separates application-local points from the real
window's transformed screen location. It never forwards keyboard events. Each
press retains its original source for release, and tagged forwarded events bypass
the native gesture bridge. The green-button bridge also hit-tests extra display
placements and dispatches the existing canvas-fullscreen/Option-fit command.

This is source implementation, not complete native multi-display acceptance.
Live popup/sheet replicas are now implemented through separate member streams;
clipping the real native window at its output's boundary remains open: the helper
currently changes a transform and alpha, not
the window's clip. Additional-display interaction, capture sharpness at different
native scales and frame pacing have not been exercised. The no-launch app build
and strict compiler checks passed; no tests, fixtures or applications were launched.

`native-replica-family.m` captures each freshly parented child independently and
orders children by observed WindowServer stacking. Frame metadata supplies the
source pixel crop; native extents are normalized relative to the root for every
display's camera. Separate frame queues avoid waiting behind family discovery.
Capture size/rate changes update existing streams, and downsizing follows the
root's demand hysteresis. Observation and stream-start deadlines reject stale
work, with at most one uncancellable shareable-content request outstanding.
Permission loss, changed ancestry/bounds or retired generations withdraw child
images. The renderer carries image geometry only, includes children in closing
snapshots and window screenshots, and refuses invalid source crops.

Live captured families now share one validated ordering plan with pointer hit
detection. A complete on-screen native stacking observation can interleave roots and
children within one contiguous compositor bucket only when every captured
member matches and the observed root order agrees with the controller. Physical
native placements, stand-ins and closing snapshots are barriers. Missing or
incompatible evidence keeps the grouped order. Semantic order changes refresh
the existing output frames; unchanged video frames reuse the ordering plan.
Input reads that applied description and an exact child key, refusing stale
layout, source bindings, provider revisions or withdrawn images. This is not a
presentation acknowledgement or proof of physical popup behavior. Total stacking
between real windows and replicas and cross-family closing interleaving remain
open; closing snapshots preserve only
the applied relative order within the closing family.

One-shot screenshots now record a separate request-scoped stacking cohort and
opaque child keys, then re-read the complete family, bounds, relative order and
binding before composition. The renderer interleaves only complete ranked
families whose root order agrees with the frozen canvas snapshot. Offscreen or
otherwise unranked families still capture in a stable grouped order and act as
barriers. Stand-ins, widgets and canvas pin exclusion retain their existing
rules. Region clipping follows ordering, and an isolated window includes just
its complete family. Exports do not borrow live-stream ordering evidence. This
implementation has compiler/source-review coverage only; no new screenshot or
native application experiment was run.

An observed child can now remain visible in a display view after its root leaves
that viewport. The adapter adds a child-only replica placement using that
display's camera, without expanding the root's world rectangle or choosing it
as a real native owner. Its clipping envelope requests capture and rendering;
only an exact captured child hit can authorize input inside it. Fullscreen and
display-pin isolation still apply. Capture demand, drawing and pointer routing
share the derived presentation snapshot. Family reports are bound to the current
identity, generation, native bounds and session; delayed reports from a departed
or replaced session cannot restore them.

Replica hits retain the captured root generation and exact child identity.
Fresh root ownership and parent checks precede posting. A release returns to the
already-pressed identity even if its native bounds changed; it never retargets
another hit. A click waiting for native focus also retains its original root or
child identity, binding generation and output before focus changes. If the fresh
hit names another recipient, its queued down, drag and release are discarded
together. Source removal, session departure and capture cancellation also discard
pending clicks and their timers. Click navigation waits behind delivery rather than moving the view
while the initial press is pending. Child hover uses the freshly validated recipient even beyond its
root rectangle, while retaining controller pick/grab rules and application-owned
panel focus. `native-tablet.m` preserves physical pen/eraser payloads, pressure,
tilt, rotation and proximity. Admitted contact stays with its original recipient;
cancellation pairs held mouse buttons, pressure release and tool-out. A physical
enter is required for a tool already in proximity at startup. Tablet display
mapping is excluded by the owner's review. Replica cursor-image synchronization
and hardware delivery remain incomplete or unverified.

`native-pointer-grab.m` retains the original native root/member and output after
an admitted mouse press. Motion and releases map through that output's current
view even beyond tile/display bounds, without retargeting a different window.
Multiple buttons remain paired independently; cancellation releases the admitted
recipient and consumes the remaining physical tails. Stream failure, source
removal, display rebuild, event-tap disable and session departure cancel the
capture. Forwarded tags bypass the event bridge before physical-pair bookkeeping.
`native-relative-motion.m` converts accelerated mouse deltas to application
points with fractional carry; raw unaccelerated fields and tablet data remain
unchanged. This supplies neither application-requested pointer lock/confinement
nor native cross-application drag-and-drop. No physical acceptance is claimed.

`canvas-cursor.m` now coordinates Infinify's own pointing-hand cursor for pick
targets, all eight border/drag resize cursors, and a closed hand during mouse
pan/move grabs. Only the actual canvas panel under the pointer can set them;
other applications, the Dock, menus and the chooser retain their cursor. Entry,
coalesced motion, scene changes and release refresh the policy. Session departure
and panel teardown withdraw it, restoring the saved application-local cursor
only while Infinify still owns the override. Unchanged cursor sets are suppressed.
Native-mode hover forwarding is enabled for captured views; physical native
recipients continue to answer `forward: false` and are not reposted. No physical
cursor or hover acceptance has been performed. A foreign application's cursor
image, hotspot, visibility and animation over a replica remain unimplemented;
neither the global cursor getter nor cursor pixels in a capture bind them to the
replica's exact recipient and remapped point.

The 2026-10-11 source performance pass reuses settled background plans across
time-only changes, stops TIFF visibility scans when the cache budget is exhausted,
batches retired-resource removal, shares one uniform upload across effect strips,
coalesces drawable notifications and retries failed drawable acquisition only
when the owner still owes a scene. Controller snapshots, hits, input checks and
resize-border queries read settled state without cloning the whole controller.
Mutations and public scene load finish normalization themselves; lifecycle marks
are pruned before fullscreen settlement. The native shell retains its decoded
snapshot across those four reads and invalidates it before any other command.
Shared GPU queues and cross-queue
synchronization remain intact. Family worker queues drain temporary Objective-C
objects after each work item, and an empty child plan skips shareable-content
enumeration while still retiring old streams through the usual reconciliation.
An ancestry walk reuses each freshly validated parent as the next step's
before-check, while retaining a fresh after-check around every private parent
read. The direct-child capture path therefore makes five window-info queries
and four process-birth reads instead of six and five, by source inspection.
No validation result is cached across frames, and final frame metadata remains
freshly checked after bounds validation.
Drawable child-attachment arrays are retained across ordinary pixel changes and
rebuilt before membership, first-frame, failure or retirement callbacks. Rank
cohorts compare relative managed-window order, so unrelated desktop windows do
not trigger redraws, and unchanged capture descriptions reuse their state.
Normal composited root captures now receive callbacks on a serial worker with
a separate mailbox for each stream. At most one latest sample waits behind one
main-thread drain. Coalescing carries dirty/unknown-dirty and size changes into
the retained complete frame, so a later unchanged frame cannot hide an update.
Retirement cancels the old mailbox, and publication checks the exact source,
stream and mailbox on main. Controller, renderer and capture installation stay
on main; experimental resize and display-layer capture keep their existing
callback path. This does not guarantee that ScreenCaptureKit moves every internal
deserialization operation off main. Ordinary overlay input also reuses its first
successful router validation within the straight-line pre-controller check;
bounds refresh, controller input and posting retain their subsequent validation.
These are unmeasured source optimizations.
A bounded read-only process sample at 21:11:52–21:12:02 UTC found no running
Infinify. WindowServer used approximately 45.5% of one CPU by cumulative-time
delta and 546.5–546.6 MiB RSS for the whole desktop. This is not an equivalent
workload comparison or evidence of improvement. No tests, fixtures, apps or
benchmarks were launched; CPU/memory parity and stable 120 fps remain unverified.

After the owner enabled live profiling and launched Infinify, a read-only
15.006-second observation at 22:07:32–22:07:47 UTC measured 3.56 CPU seconds
(23.7% of one core) and 107.64–191.31 MiB RSS for PID 3542. WindowServer used
8.46 CPU seconds (56.4% of one core) and 570.0–570.6 MiB RSS for the entire
desktop. A later five-second stack sample reported physical footprint 389.1M,
peak 498.4M; that metric and time are distinct from the RSS interval. The app
had no launch flags: this measured the default capture overlay, not native-helper
presentation. Its loaded executable UUID was
`874BAD98-BBFF-397E-BA23-13A73AA87660`, matching the bundle built at 19:57:36 UTC,
before the current source changes. The sample contains main-thread capture
processing, snapshot JSON and pointer-validation work; blocked drawable waits
are not evidence of CPU spinning. No before/after improvement, steady-state
memory bound, native workload comparison or 120 fps acceptance follows from
this sample. Saved local evidence is under
`target/performance/20261011-live-overlay/`; no app was launched or restarted by
the profiler.

Native clipping currently exposes identity-bound geometry plans through
`DebugNative`, with `planning_only` and `native_supported=false`. No shape write
is enabled: exact original-region snapshot/restoration is not implemented. These
source additions passed strict compiler checks without tests or desktop activity;
they establish neither usable third-party compositing nor stable 120 fps.

Audited allowlist helpers bind only verified native roots. The read-only native
family adapter requires an acyclic WindowServer parent chain, one process birth
and finite untransformed bounds for every popup or sheet. Children follow the
root's canvas scale and placement and do not become independent world windows.
An invalid or changed report restores prior children; a removed child restores
its exact original transform and alpha. Creation, appearance and child-change
hints request an immediate serial worker read, coalesced to one follow-up when a
batch is already in flight. Cached associations cannot authorize input: a child
recipient must still pass fresh process, bounds and parent-chain checks. Its
canvas gestures use the root's binding context even outside the root tile.
The same path can be exercised by a cooperative owned host advertising fixture
family capability; this is preparation for broader support, not evidence of
usable third-party popup/sheet compositing. Native one-shot exports make a fresh
audited family plan, capture each member independently without implicit child
flattening, and compose children in their observed order. Normalized image offsets
preserve extents outside the root without changing its canvas geometry. A changed
identity, ancestry, native frame or family membership/order cancels the export.
The upstream target region still decides the crop; family pixels do not expand
the root's world rectangle or its screenshot contract.

`python3 tests/e2e/scoped-native-family.py --live-owned-fixture` passed on
2026-10-11 with one newly spawned root, a real AppKit child popup and a sheet.
One logical root produced three helper records. An independent WindowServer
connection checked child offsets at zoom 0.5 and 0.85 after a settled camera
pan; native untransformed frames stayed unchanged. Normal quit restored all
three exact original transforms, alpha values and bounds before removing the
children. Evidence: `target/ipc/family.jhw9lwjq/result.json`. This establishes
owned-fixture geometry and restoration, not third-party compositing acceptance.
Focused child-window observations give the parent logical canvas focus while
keeping the native leaf focus distinct; they never assert native focus on the root.

Independent floating utility panels remain fixed to their display, as the owner
chose on 2026-10-11. Native discovery accepts the actual floating window level
only when Accessibility confirms `AXFloatingWindow`; no title or size heuristic
admits a panel. Its initial output-local position becomes a canvas screen pin
atomically during attachment. A saved pin retains its saved placement. Panel
arrival does not focus it, fly the camera or invoke root-window opening rules.
The generic canvas pin owns no native coordinates; the adapter supplies the
output and position. Popups and sheets remain members of their root's family.

`python3 tests/e2e/scoped-native-panels.py --live-owned-fixture` passed on
2026-10-11 with one newly spawned normal root and one independent AppKit utility
panel. Independent WindowServer reads found the panel's transform, screen
rectangle and native bounds unchanged through a settled pan and zoom 0.5/0.85,
while the root followed the canvas. Quit restored both original transforms,
alpha values and bounds before cleanup. Evidence:
`target/ipc/panel.s0fs_1qf/result.json`. This establishes the owned-panel policy
and restoration; third-party panel behavior remains unverified.
The owner also chose to retain the application's native stacking and keyboard
focus on 2026-10-11. The adapter leaves those with WindowServer and the application;
it does not apply synthetic exclusive focus or panel-level overrides.

Configured mouse gestures can also begin over the real window: the native input
bridge routes pan, world move, resize, center-nearest, actions and modifier scroll
through the same handlers as the canvas. It checks the actual destination window,
current process identity and canvas hit before taking a press. Ordinary app input
is delivered directly by macOS. A taken button's drag and release stay with their
original canvas view; scroll endings and momentum stay with a taken scroll.
Helper loss, a disabled event tap, shutdown and panel replacement cancel grabs.
The bridge uses existing Accessibility/input access and requests no permissions.
AppKit-convertible magnify events from the annotated event tap now enter the
same two-finger pinch bindings over a freshly validated native root or child.
The public all-events mask avoids inventing a private CG event number; keyboard
events and unrelated event kinds return unchanged. Admission is decided once
for each pinch: an unbound pinch stays with the application, and a taken pinch's
remaining phases stay swallowed after cancellation. This is compiled source
support, not evidence that macOS delivers magnify through that tap on the target
host. Raw multi-finger touch delivery over native windows remains open.

Native mouse motion also enters the existing coalesced hover frame/timer path.
At flush, the actual WindowServer recipient is resolved afresh to a current
logical source and binding generation, instead of trusting canvas stacking.
`focus_follows_mouse` can then focus that source in place. Ordinary mouse motion
continues to the application directly; the canvas never reposts it. Independent
floating panels keep their application's focus and stacking.

An unchanged-size move of the native root's own frame is an owner movement,
distinct from the helper's transform. The adapter submits its unscaled
displacement with the previous and current source rectangles and binding
generation. The controller consumes that transition once, moves a canvas root
without changing its camera or focus, and moves a display pin within its existing
output bounds. Compositor grabs, fullscreen and pending size restoration retain
their own geometry. Physical titlebar behavior and displacement units at
different zooms are unverified.

Native session watching now includes native windowed runs. Leaving the user
session or sleeping cancels gestures and frame driving, ends helper placement
immediately and drains exact restoration on workers. Physical button-pair
bookkeeping remains until the swallowed down events have had their releases.
On return, worker preparation reuses only launch-time helper endpoints, nonces,
PIDs and birth timestamps. Every helper must authenticate and report its exact
disjoint enrolled scope again, and its probe must report an empty restore table.
Only then does main-thread admission start a fresh watchdog and re-observe
bindings. Retry backoff is bounded at 30 seconds; a stale completion or shutdown
discards its inert candidate. No helper is loaded or process implicitly enrolled.
Windowed canvas panels retain ordinary application ordering on return. Actual
sleep, session switching and recovery have not been exercised.

Native one-shot screenshot capture now retries selected transient
ScreenCaptureKit setup/connection failures twice, after 80 and 160 milliseconds,
within the original two-second request deadline. Each retry uses a fresh
shareable-window list and repeats the existing identity, generation, native
parent-chain and own-bounds checks against the original family plan. Permission
and configuration failures remain final; no stream or helper mutation is added.
The earlier cold-capture failure motivated this source change; successful runtime
recovery is unverified.

These continuation changes were compiled and inspected on 2026-10-11. No tests,
fixture launches or third-party application experiments were performed after
the owner stopped desktop testing. Compilation does not establish native
application compatibility or stable 120 fps.

The native green control toggles fullscreen inside the canvas. Option-click
toggles fit, carrying snapped neighbours when `mouse.decoration_fit_snapped`
is enabled. A bounded worker reads the exact root's Accessibility fullscreen
or zoom button; input uses cached window-relative control bounds and fresh
process/native-bound checks. A resized root invalidates that geometry. The
clicked source identity and generation reach the controller directly, so focus
on another window cannot redirect the command. A taken press owns its release;
dragging off the control cancels it. No native fullscreen Space is requested.
`DebugDecoration` requires `--debug-pointer`, native presentation and an explicit
process scope. Its probe reads the actual control; its click calls the bridge
directly without posting input. It cannot establish physical event delivery.

`python3 tests/e2e/scoped-native-decorations.py --live-owned-fixture` passed on
2026-10-11. The handler used the actual AX green control on one newly spawned
fixture root, toggled fullscreen and Option-fit, and restored each original
size. Independent WindowServer reads checked all four sizes and that a second
fixture window's native bounds stayed unchanged. Quit restored both exact
original transforms and alpha values before cleanup. Evidence:
`target/ipc/green.s0mvzn2h/result.json`. This validates the scoped handler and
owned native resizing; physical green-button delivery and third-party use remain
unverified.

Session sleep, display sleep and leaving the login session cancel canvas grabs,
pending focus and camera flights. A Space notification cannot restart them while
one of those states is still held. The existing system settings remain in charge;
the port requests no power, lock or permission changes. A helper whose lease ends
during sleep ends that presentation session; the separately audited reconnection
path above prepares a replacement session after return.
Screen-parameter notifications rebuild panels only when a display's identity,
full frame, backing scale, cadence or coordinate origin changed. A Dock usable-area
notice retains the existing panel, output and compositor layer. A genuine display
change ends the old frame driver before replacing its layer.

Native screenshots obtain one-shot ScreenCaptureKit images for the selected
bound windows, then compose those pixels into the canvas export. The PNG uses
the requested canvas scale, but native images have the pixel density of the
transformed window: zoomed-out images contain less detail. No transform is
temporarily undone to obtain sharper pixels.
This requires existing Screen Recording access, checks ownership and native size,
and has the same two-second deadline as overlay exports. Preparation returns the
IPC handler immediately and continues through callbacks, so cold capture setup
can use the main queue while other connections remain responsive. Timeout and
shutdown prevent late samples from being installed. Single-window snapshots
ignore display clipping. It creates no capture stream and changes no window
transform or live rendering budget. Without access the screenshot request
returns an error.

The owned family export scenario has partial evidence at
`target/ipc/family.ez6vd0s_/family-0.5.png`: a 438×410 PNG contains the popup above
and to the left of the root and the sheet inside it. Independent saved PNG-byte
inspection found both child colors within rectangles calculated from native own
bounds and public world geometry. The scenario did not complete: its initial
saturated-orange threshold did not match the appearance-dependent color, and a
later run encountered ScreenCaptureKit's audio/video capture setup failure.
Neither run is recorded as a complete E2E pass. All owned children were restored
and removed; further live validation stopped at the owner's request.

After composition, an immutable image moves to a serial worker for PNG compression
and file writing. The IPC reply waits for that write while input and frames can
continue. Offscreen Metal composition and readback still run on main. Requests
remain serialized so only one export image waits for compression.

Quit restores each original transform and alpha before the rest of shutdown.
The helper also restores on client loss or lease expiry. A separate watchdog
closes the session if the main run loop stops for ten seconds; protocol threads
never wait for the main thread to release their client. Helper loss is reported
once, leaves the IPC server responsive, and ends native presentation for that
run. Reconnection or a switch to capture is not automatic. See the
[helper's recovery contract](../privileged/README.md#recovery-limits-and-evidence).

Unbinding a live window queues restoration of that window's original transform
and alpha through the helper's negotiated per-window restore capability. Other
bound windows keep their placements. A pending release is retained until its
frame is acknowledged; retries use the helper's journal and recovery path.
An older helper without this capability ends and restores the whole session on
unbind. The focused helper release scenario passed with exact transform/alpha
readback and seven other windows unchanged.

`./tests/e2e/scoped-native.sh` is read-only by default. Its explicit
`--live-owned-fixture` mode starts disposable fixtures, checks startup refusals,
adoption, focus, pan, zoom, move, resize, alpha, parking, continuous movement,
quit, client SIGKILL, a stalled main thread, helper loss and the default overlay
path. An independent WindowServer connection checks transforms and alpha before
and after recovery; a second disposable process checks that the scope excludes
its windows. Children are removed on every exit.

On 2026-10-11 this test passed three times on arm64 macOS 27.2, with 101 checks per
run on one 2056×1329-point, 120 Hz display. The protocol fixture scenarios also
passed (v1 and all 21 v2 cases). These are cooperative owned-window observations;
they do not establish third-party window compositing or macOS 26 runtime support.
The subsequently added physical event bridge builds cleanly; real mouse and
trackpad input through that bridge has not been exercised. A separate focused
native export check produced a 696×520 PNG of the fixture's real title and content
at zoom 0.5 from its 320×232 transformed raster. Capture did not change transform
or alpha, started no live stream, and normal quit restored the exact originals.
The same focused export check also passed with PNG compression and writing on
the serial worker.
This validates export geometry and pixels, not untransformed resolution or
third-party compositing.

Remaining boundaries: extra output views now use shared live root captures,
while the real window stays at one stable native placement. Live popup/sheet
replicas are implemented but unverified; native clipping to an output boundary
remains open. Raw
multi-finger trackpad gestures over real windows, physical
delivery of the new magnify bridge, Spaces gathering,
native popup placement and ordering across applications still require further
integration. A Dock or other third-party host has not been loaded
or validated by these tests.

### What was run for managed windows

On 2026-10-09 (macOS 27.2, Apple Silicon): `./scripts/build-app.sh`, the
controller scenarios in `crates/desktop/tests/lifecycle_flow.rs` through the
exported C ABI, and four short launches of the built, ad-hoc signed app on a
private scene, config and socket, driven by a script through `Infinify msg`.
The launches had **no Screen Recording and no Accessibility grant**, so
discovery stayed inert and every window was a seeded placeholder: three slots
a save recorded as open, with a bundle identifier (`org.example.seed`) that
belongs to no application. Nothing from them is saved as evidence. Observed:

- `--windowed 1100x700` opened its one panel (1100x700, normal level, read from
  the system window list), printed the not-managed line on stderr and answered
  `msg state` with the three placeholders, all `suspended`, on one output of
  1100x636.
- No discovery pass ran, so the pass rule was not applied: three seconds after
  launch nothing had been dropped, in a run without `restore_windows` and in
  one with it. That flag was therefore not exercised; its outcomes are covered
  by `lifecycle_flow` only. Leaving the scene alone is the intended behaviour:
  without a discovery pass the app cannot tell an open window from a closed
  one.
- `msg focus --id 1` then `msg action close-window`: placeholder 1 gone.
  `msg close --id 2`: gone. `msg suspend --id` on a placeholder: `window is
  already suspended`; on an unknown id: `no window with id 99`.
- `msg relaunch --id 3`: `ok`, the `Relaunch failed: …` line on stderr, and the
  app kept answering. Asked again a second later: `ok` and no second line,
  because that relaunch was still pending. With an unknown id:
  `no suspended window matching selector`.
- Restart: the file that windowed run saved held the one placeholder left, with
  no pid or window number anywhere in it. A reseeded scene of three survived a
  windowed run and two `--manual` runs with `restore_windows = true` unchanged.
- `--manual`: one window of the chooser's size (720x502) at the chooser's level
  and no canvas (`msg state` lists no output), nothing on stderr, the three
  placeholders untouched.
- Every launch exited 0 on SIGTERM and removed its socket.

Not run, because it needs the grants: the canvas opening by itself at launch,
discovery, adoption of a running window into its slot, a slot kept for a window
that is off screen, placement of a real window, the drop at the end of a pass
(at launch or on reopening), `window_closed` and `retitle` for a real window,
who takes the focus after a real close and the camera flying there, capture
starting and stopping on demand, a failed read being tried again, the close
button press, a relaunch that opens an application and its adoption. Also not
run: a relaunch or a close request lapsing in the app (no launch lasted thirty
seconds), a refused config file at launch, Return to desktop and Open canvas,
⌃⌥Q or any other hot key, more than one display, and anything drawn, the
not-managed status line included (only its stderr copy was read). Those paths
are compiled, type-checked and read, nothing more. Six earlier launches the
same day ran on the build before the review fixes and are superseded by these.

**The build that holds this together with window navigation, hot corners, the
event stream and autostart** was launched once more that day, as
`--windowed 1100x700` for 20 seconds on a private scene (the same three seeded
slots), config (`autostart = ["printenv INFINIFY_SOCKET > FILE"]`) and socket,
driven through `Infinify msg`. It had no Screen Recording access. The
missing-Accessibility note was not printed, so that access presumably existed;
it was not checked. Nothing from it is saved as evidence. Observed:

- the not-managed line on stderr at launch; `state` with the three slots at
  `[520, -360]`, `[1950, 0]` and `[-620, -890]` on one output `windowed` of
  1100x636, camera `550 -318`;
- `action center-nearest right`: `focus` answered window 2 and `camera` read
  `1950 -0` (the client prints the negative zero); `action pan-viewport right`:
  `2050 -0`; `action zoom-to-fit`: camera `750 -390`, zoom 0.28484848484848485,
  and a second one back at `2050 -0`, zoom 1;
- `--json state`: the three windows, all `suspended`, the focused one first;
  `focus --id 1` then `action close-window`: two windows left and no focus;
- `suspend --id 2`: `window is already suspended`; `relaunch --id 2`: `ok` and
  the `Relaunch failed: …` line on stderr, asked again: `ok` and no second line;
  `close --id 99`: `no window with id 99`; `relaunch --id 99`: `no suspended
  window matching selector`; `action suspend-window` with nothing focused: `ok`
  and nothing changed;
- `action exec printenv INFINIFY_SOCKET > FILE` and the autostart command each
  wrote the path of the socket this instance served;
- a `msg subscribe` client received 109 states, the first with three windows
  and the last with two: the dismissal reached the subscriber;
- SIGTERM: exit status 0, the subscriber exited 0, the socket was removed.

No window had a bound source in that launch either, so no focus request was
produced: that the request of a new window, or of the window that follows a
close, reaches the coordinator and enters the most-recently-focused order rests
on the controller scenarios (`lifecycle_flow`, `navigation_actions_flow`), the
headless coordinator regression and a reading of the shell. The status line was
not read, so neither was the not-managed note sharing it with the
Accessibility note.

### Event-driven tracking

Until this build the shell learned everything about native windows by asking:
the window list every 80 ms for new windows, closes, frames and titles, and
the frontmost application's focused window twice a second. A managed run with
Accessibility access is now told instead, the way the yabai window manager is,
and keeps the asking as a slower safety net. There is no flag, no new control
and no new permission: it is on whenever the app manages windows (Screen
Recording access, no `--manual`), the per-application observers need
Accessibility access, and it uses
public Accessibility and `NSWorkspace` API plus the one private call the
window test already used (`_AXUIElementGetWindow`). **None of it has run in
the app on a real window**; [what was run](#what-was-run-for-event-driven-tracking)
says what has.

What is observed (`native/desktop/window-events.m`):

- from `NSWorkspace`: an application launched, terminated, activated, hidden
  or shown again, and the active Space changed;
- from one Accessibility observer per regular (Dock) application, created when
  the application launches or at startup and removed when it ends: a window
  created, the focused window changed, a window moved, resized or retitled;
- from each window that observer knows: destroyed, miniaturized,
  deminiaturized.

An event is never taken as the change itself. It only says where to look now,
and the looking is the code the poll runs: the window list is read again, and
what it shows is reported to the controller as before. So an event that is
repeated, late, or followed by the poll finds nothing new and sends nothing
twice.

| Event | What happens at once |
| --- | --- |
| application launched | it is observed; its windows are looked for |
| window created; window deminiaturized; application shown again | that application's windows are looked for: a new one is offered by the rules above (the Accessibility subrole test; still for 50 ms) |
| active Space changed | every application's windows are looked for |
| window moved, resized, retitled or miniaturized; application hidden | that window is looked at, or every managed window of the application when the event names none: a new title or frame is reported (`retitle`, `observe`) |
| window destroyed | that window is looked at: it leaves the canvas if the window list has dropped it or it is off screen, and is otherwise looked at on every poll for a second |
| application terminated | its observer is removed and its windows are looked at, which finds their process gone |
| application activated; focused window changed | native focus is read through the same path as the focus poll ([Native focus is followed](#native-focus-is-followed)) |

Each look is made when the event arrives and once more 80 ms later, because
the window list can show a change a moment after the application reports it;
a storm of events (a live resize reports every step) is one look at once and
one per 80 ms after it. After an event that may bring a window on screen the
poll also looks for new windows every 80 ms for a second.

**The poll stays.** The app's 80 ms timer still ticks the clock, the camera
and the hot corners and redraws. What changes is how often it looks at
windows: while every regular application is observed in full, new windows are
looked for and every managed window is looked at once a second, and native
focus is read once a second, as a reconciliation that finds whatever no event
announced. A window whose capture failed, one reported destroyed and still on
screen are still looked at on every poll. Without Accessibility access, and while some
application is not observed in full (it has not answered yet, or refused a
notification), the poll runs exactly as before, every 80 ms and focus twice a
second; without that access the `NSWorkspace` events are all that arrives
besides. Accessibility access is read again once a second, so a grant
made while the app runs starts the observers and one withdrawn removes them
(not tried). A run that manages no windows (`--manual`, no Screen Recording
access, the probe, demo and owned modes) has no observers at all.

**A slow application does not hold the canvas.** Every Accessibility message
the observers send is sent off the main thread with a quarter-second timeout;
on the main thread an event only looks its window up in a table. An
application that does not answer is asked again five times a tenth of a second
apart and then once a second. A window whose application did not answer when
an event first named it, or gave no window number for it yet, is asked about
again by the next event that names it, and that application's windows are
listed again once a second until it does.

**Minimized windows, hidden applications, other Spaces.** What each does is
unchanged:

- A managed window that is minimized, whose application is hidden or that is
  on another Space is not closed: its window number is still in the window
  list. Its tile stays where it is with its last picture, and its title is
  still followed.
- A window in one of those states that is not managed yet is not offered: only
  windows on screen are. The first pass names it, if it has a title, so its
  saved slot waits for it; it is offered when it comes on screen.

What is new is when: miniaturizing a window or hiding its application is
looked at as it happens (and changes nothing); a window coming back from the
Dock, an application shown again and a change of Space look for windows at
once instead of at the next poll.

**What the owner will notice.**

- Command-Tab, the Dock, or an application raising its own window is followed
  when it happens, where the canvas used to catch up within half a second.
- A native move or resize, a new title and a close reach the canvas with the
  event instead of at the next 80 ms poll, and a new window is looked for when
  its application reports it. Against an 80 ms poll that is a small gain; the
  larger one is that an idle canvas reads the window list once a second
  instead of twelve times.
- One rule is new, and it is the only change to which windows count as
  closed: a window its application reported destroyed is closed once it is
  also off screen, even if the window list keeps its number. The poll alone
  never did that. It is meant for an application that keeps a closed window's
  object, whose tile used to stay for good.
- The safety net is slower than the poll it replaces: a change no event
  announces is found within a second, where it was found within 80 ms.

**Known limits**, from reading the code:

- The new close rule has not been seen on a real window. Which applications
  report a window they keep as destroyed is not known. If an application
  reports a native tab as destroyed when another tab is selected, that tab's
  tile leaves the canvas on every tab switch and is placed afresh when the tab
  is selected again, where it used to stay with its last picture. Minimizing
  and hiding are not expected to do this. The rule is one line
  (`-destroyed:info:` in `main.m`, the `kCGWindowIsOnscreen` test); without it
  a destroyed report only makes the window list be read at once.
- One application that does not answer, or refuses one of the six
  notifications for good, keeps the whole poll at its old pace for every
  application: nothing is lost against the previous build, and nothing gained
  either while it runs.
- An application lists only the windows of the active Space, so a window on
  another Space is watched for destroyed, miniaturized and deminiaturized only
  after its Space was shown or its application activated. Until then its close
  is found by the reconciliation, within a second.
- A window is watched for those three only once its application has said
  which window it is. While an application does not answer that within the
  quarter second (a document opened while it is busy), or answers with no
  window number yet, the poll does not return to its old pace: the window's
  close is found by the reconciliation, within a second, until a later event
  or the once-a-second listing has it answered. An application that keeps
  listing a window without a number is listed once a second for as long as it
  does. Whether any application announces a window before it has a number is
  not known; yabai drops such an element.
- A destroyed report that is missed while the window list keeps the window's
  number leaves the tile on the canvas, as before.
- An application that becomes a regular one after it launched is observed at
  the next reconciliation, within a second.
- An application's first window can appear after the second of 80 ms looks
  that followed its launch. It is then found by its created event, or by the
  reconciliation up to a second later.
- Title changes are reported for elements that are no window. Each is taken as
  "some window of this application may have changed" and looks at that
  application's managed windows, at most once per 80 ms.
- Registering for a notification may not honour the quarter-second timeout.
  It runs off the main thread, so an application that stalls it delays only
  the observation of other applications, not the canvas.
- A close the controller refuses, with the release of the source refused too,
  is reported again at every look, as before this build.

### What was run for event-driven tracking

On 2026-10-10 (macOS 27.2, Apple Silicon), from a session with **no Screen
Recording access**; Accessibility access was read as granted by the throwaway
program below, and the app did not print its missing-access note:

- `./scripts/build-app.sh`: built and ad-hoc signed, with `window-events.m`
  compiled under `-Wall -Wextra -Werror` and linked.
- The controller scenarios through the exported C ABI: `lifecycle_flow` (32,
  seven of them for reports that are repeated, late, early or out of order),
  `controller_flow`, `navigation_actions_flow`, `focus_cycle_flow`,
  `navigation_flow`, `effects_flow` and `rules_flow`, all passing.
- `./tests/e2e/desktop-navigation.sh`, the headless coordinator regression,
  passing with the coordinator's one change (a read of native focus asked for
  while one is under way is followed by one more). None of its scenarios asks
  during a read, so that change is compiled and read, not exercised by it.
- Four launches of the built app, the fourth on the final build,
  `--windowed 1100x700`, on a private scene (three seeded slots), config and
  socket, for three seconds each, driven through `Infinify msg`, with the
  same result: `state` listed the three windows on one output `windowed`
  of 1100x636 at camera `550 -318`; `action center-nearest right` answered
  `ok` and `camera` settled at `1950 -0` with window 2 focused; SIGTERM, exit
  status 0, socket removed. stderr held one line, the not-managed line.
  **Those launches had no window manager, so no observer was created in
  them**: they show that the build starts, serves IPC and exits cleanly, and
  nothing about events. The observers also print nothing, so an empty stderr
  would say nothing about them either.
- A throwaway program outside the repository, observe-only, built with the
  address and undefined-behaviour sanitizers around the real
  `window-events.m` with a sink that only counts: of 7 regular applications
  running, none was observed at start and all 7 had their observer on the run
  loop with all six notifications registered half a second later, 2 windows
  watched; four "some window of the application changed" reports arrived
  across its two instances and no other kind; after `-stop` no application was
  observed and the object was released; a second instance released without
  `-stop` was clean; exit 0 and no sanitizer report. It registered for
  notifications and read window numbers and roles; it posted nothing and
  moved, focused or closed nothing. It ran `window-events.m` as it was before
  its last two changes (a window its application did not answer for, or gave
  no number for, is asked about again and its windows listed again; a window
  watched twice, by a
  listing and by an event at once, keeps one record), and was not run again:
  those two are compiled and read, nothing more. Earlier runs of the same
  kind that day, not repeated for this entry, drove the real
  `window-manager.m` under a host that binds nothing and counted its passes,
  and the real coordinator with a canned controller and job queues.

Not run, because it needs Screen Recording access and a real window, and no
test may move, focus or close one: any event reaching the app; a window
created, destroyed, moved, resized, retitled, miniaturized or deminiaturized
there; an `attach`, `window_closed`, `retitle`, `observe` or native `activate`
sent because of an event; the destroyed-and-off-screen close; Command-Tab
followed without the wait; the once-a-second reconciliation in the app; a
grant made or withdrawn while it runs; an application that does not answer.
Those paths are compiled, type-checked and read, nothing more.

**At the merge with the tap bindings and the background caches, the same
day.** Everything above ran on the tree the events were built in, which had
neither. The tree that landed has the [tap tracker](#tap-bindings), the
[usable rectangle](#the-usable-area) the controller keeps and the shell never
sends, and the [background caches](#background-caches) beside the events;
`./scripts/build-app.sh` compiles `window-events.m`, `tap-keys.m`,
`frame-driver.m` and `background-tiff.m` once each and built it as written.

- **Read at the join**, in the code, not run:
  - The app's poll does what it did on both sides: the lost-input check, the
    display link's fallback for a frame timer that has stalled and the
    capture report of a resize run stand beside the reconciliation. The tap
    tracker is still no part of it; it is only told the Accessibility trust
    the shell reads with each read of native focus, which a focus event now
    makes too and which the poll makes once a second, not twice, where the
    observers are in place ([Tap bindings](#tap-bindings) says so now).
  - Which windows are adopted is decided in one place, for a pass an event
    started as for the poll's: an event only runs the pass, the pass's one
    read of the shareable windows asks Accessibility for the subroles in its
    completion handler, off the main thread, and the test on that answer
    stands before the only call that offers a window. A window the poll
    would refuse is refused when an event announces it, and one of a
    window's size is named on stderr once per appearance, as before.
  - Quit and Return to desktop stop the window manager with its observers,
    the tap monitors and the frame timer once each (the later stop of the
    keys finds no tracker left). A screen change stops the frame timer and
    the tap monitors once, starts the taps again with the hot keys, and
    keeps the window manager and its observers, as it kept the manager
    before there were observers.
- **The controller**, nine test modules through the exported C ABI, all
  passing: `lifecycle_flow` (32), `controller_flow`,
  `navigation_actions_flow`, `focus_cycle_flow`, `navigation_flow`,
  `effects_flow`, `rules_flow`, `usable_tap_flow` (15) and `motion_flow`,
  115 scenarios, and `./tests/e2e/desktop-navigation.sh`. The repeated native
  activation and the usable rectangle meet in the controller
  ([contract](../../crates/desktop/LIFECYCLE.md#event-delivery)).
- **The app, one launch** of the landed build, `--windowed 1100x700`, on a
  private scene of three seeded slots, a config holding an `alt+shift` tap
  and a private socket, for 4.1 seconds: `state` listed the three windows on
  one output `windowed` of 1100x636 at camera `550 -318`; `action
  center-nearest right` settled at `1950 -0` with `#2` focused,
  `pan-viewport right` at `2050 -0`, `zoom-to-fit` at `750 -390`, zoom
  0.28484848484848485, and again back at `2050 -0`, zoom 1; a viewport
  capture of 1100×636, opened, showed the Browser placeholder over the dot
  grid; `reload-config` answered `ok`; SIGTERM, exit status 0, socket
  removed. stderr held one line, the not-managed line. **That launch had no
  window manager either, so no observer was created and no window event was
  driven**: everything listed above as not run is still not run, and no tap
  was made, a windowed launch installing no monitor.

## Window rules, widgets and pinned windows

DriftWM's per-window policy for the windows on the canvas: `[[window_rules]]`
in the config file, widgets fixed to the canvas, and windows pinned to a
display's screen. The user contract is upstream's `docs/window-rules.md`; the
decisions are the controller's, and
[RULES.md](../../crates/desktop/RULES.md) is their contract with every
difference from upstream. **None of what this section says about a real window
has been run, and the app's own panel was never looked at**:
[What was run](#what-was-run-for-rules-widgets-and-pins) says what was, and
[What was run for rules and rendering together](#what-was-run-for-rules-and-rendering-together)
what has been drawn since, offscreen.

**What changes for an existing setup.**

- ⌃⌥T (`mod+t`, `toggle-pin-to-screen`) is now a registered global hot key in
  a normal run, taken from every application while a canvas is open.
  `"mod+t" = "none"` under `[keybindings]` gives it back.
- `[[window_rules]]` entries a config file already had now act on each window
  as it appears: `position`, `widget`, `pinned_to_screen`, `output`,
  `focus_on_open` and `opacity`, and its `decoration`, border, corner and
  shadow keys change how the window is drawn ([Rendering](#rendering)).
  `[decorations] opacity` and `opacity_focused` now dim windows too.
- `Infinify msg pin`, `msg opacity`, `msg action toggle-pin-to-screen` and
  `msg action move-to-bookmark NAME` run instead of answering not implemented.
  `msg move` and `msg resize` refuse a pinned window, `msg focus` refuses a
  widget, and `msg state` lists a pinned window under `pinned`, no longer under
  `windows`.
- The scene file gains a `pins` field while a window is pinned
  ([Persistence](#persistence-and-lifecycle)).

Since the pass rules were added (no new flag, no new default binding):

- A rule's `pass_keys` and `pass_mouse`, which a config file may already
  carry, now act. Before, they were read and kept and did nothing. With
  `pass_keys` on the focused window, the chords it names stop being
  Infinify's while that window holds the keyboard
  ([below](#passing-keys-and-presses-to-an-application)). A rule's
  `layer_order` is still read and kept and does nothing, which is what
  upstream does with it for a window ([below](#layer_order)).
- The move binding (⌥ left drag by default) pressed on a pinned window now
  drags it across its display's screen, and the trackpad move gesture (a
  three-finger double-tap and drag by default) over one does the same.
  Before, the press was swallowed with a note and the gesture did nothing. A
  resize binding still is swallowed, and the note now reads "A screen-pinned
  window is not resized: unpin it first (toggle-pin-to-screen)" (since
  [the gaps were closed](#upstream-behaviour-gaps-closed) the press raises
  and focuses the window first).
- A mouse binding on a wheel notch (`wheel-up`, `wheel-down`) now fires: one
  notch of a mouse wheel runs its action once. Before, those two triggers
  were read and never asked for. No default binding uses them.

**Matching.** A rule's `app_id` is matched against the window's bundle
identifier and its `title` against the window's title, each as an exact string,
a `*` glob or a `/regex/`, case-sensitive; a rule with both needs both.
`Infinify msg state` prints both for every window. Every matching rule applies,
merged in file order as upstream merges them: the last rule that sets a value
wins, and `widget`, `pinned_to_screen` and `blur` stay on once any rule sets
them.

**When.** Rules are resolved once, when a window first reaches the canvas, and
stay with it until it is gone. Reloading the config changes no window that is
already there, and a window that changes its title is not checked again, as
upstream documents. A window that takes a saved slot back at launch keeps the
slot's frame and pin whatever its rule says of `position` and
`pinned_to_screen`; it still gets the rest of its rule. `suspend_on_close` and
`restore_windows` are asked afresh each time, as before, and so are
`pass_keys` and `pass_mouse`, as upstream asks them: they follow the config
file and the window's title of the moment, so a reload or a new title changes
them at once.

| Rule field | Effect |
| --- | --- |
| `position = [x, y]` | the centre of the window's frame on the canvas, Y up, instead of `window_placement`; for a pinned window, measured from the centre of its display |
| `widget = true` | the window is a widget, below |
| `pinned_to_screen = true` | the window starts pinned, below: on the display `output` names (a display UUID, or `windowed`) when that one is connected, else on the active display; centred there without a `position`, and moved until the whole frame is on that display |
| `focus_on_open = false` | the window appears without taking the canvas's focus or moving a camera |
| `opacity` | the window is drawn at that opacity, focused or not, and `msg screenshot window` captures it alone at it |
| `decoration`, `border_width`, `border_color`, `border_color_focused`, `corner_radius`, `shadow` | what the window is drawn with in place of the `[decorations]` values, see [Rendering](#rendering) |
| `suspend_on_close`, `restore_windows` | see [Managed windows](#managed-windows) |
| `size` | a new window is placed for that size, as upstream places it, and asked for it as it appears, a widget and a window the rule pins included: `position` is the centre of the size named, and a pin and the placement policy take that frame too. Several such windows that appear together are asked one after another, in the order they appeared ([Window sizing actions](#window-sizing-actions)). A window that takes over a saved slot is never asked. With `fullscreen = true` beside it the window is placed for that size all the same and is asked for it only when it leaves fullscreen. Run on a fixture window (`tests/e2e/scoped-sizing.sh`); no rule has resized an application of the owner's |
| `fullscreen` | a new window whose rule says `fullscreen = true` enters DriftWM's [fullscreen](#fullscreen) once it is placed, on the display `output` names when that one is connected, else on its pin's, else on the active one; a widget, a window that takes over a saved slot, a window attached from the chooser and a window that was already open when the app started are never made fullscreen by a rule. No rule has made a real window fullscreen |
| `blur = true` | what lies beneath the window is frosted, whatever `[decorations] blur` says, also while the window is fullscreen, see [Blur, window animations and the error bar](#blur-window-animations-and-the-error-bar) |
| `pass_keys = true` or a list of key combos | while the window holds the keyboard, those key bindings are not Infinify's: the chord reaches the application, [below](#passing-keys-and-presses-to-an-application) |
| `pass_mouse = true` or a list of mouse combos | a press or scroll over the window that one of those bindings would take goes to the application as an unbound one, below |
| `layer_order = N` | kept with the window and ignored, as upstream ignores it for a regular window, [below](#layer_order) |
| `preserve_aspect_ratio` | kept with the window; nothing is constrained for it |

A file with a key the grammar does not know inside a rule is refused whole with
upstream's TOML error (`unknown field …`), and the previous configuration stays
in force. A rule with neither `app_id` nor `title`, an unknown `decoration`
mode or a non-positive `size` is a warning on stderr and in the
[error bar](#blur-window-animations-and-the-error-bar),
and the rest of the file applies.

**A widget** is fixed to the canvas.

- It is drawn below every other window, whatever was clicked last, on the
  canvas and in a `msg screenshot`; `screenshot all` does not count it when
  it frames the windows.
- A move or resize binding pressed on it starts no gesture, and the status
  line says "A widget stays where its rule puts it: drags and resizes are
  ignored". The press then goes to the widget's application as a plain
  click, as upstream's falls through to click-to-focus.
  `nudge-window`, `move-to-bookmark`, `close-window` and `suspend-window` do
  nothing while a widget holds the focus. `Infinify msg move X Y --id N` is the
  one way to reposition it, and that lasts for the session.
- An unmodified click goes to its application too.
- Closing a window never moves the focus onto a widget: when the last
  ordinary window in view closes, nothing is focused.
- It takes no part in `zoom-to-fit`, the zoom-out limit, snapping, cluster
  moves or `auto` placement, and it is left out of the focus history.
  `msg focus --id N` answers `window #N is a widget and cannot be focused`,
  `msg suspend` answers `widgets cannot be suspended`, and a bundle-identifier
  selector passes over it.
- It is never saved and never becomes a stand-in. At the next launch the window
  is found as a new one and its rule places it again.

**A pinned window** is fixed to one display's screen.

- ⌃⌥T (`toggle-pin-to-screen`) pins the focused window where it is drawn, on
  the display showing its centre; pressed again it returns the window to the
  canvas at the point under its top-left corner. `Infinify msg pin [on|off]
  [--id N]` reads or sets the same thing for any live window. Neither gives a
  status note, and at 1:1 with a still camera nothing visibly changes: `msg
  pin` or `msg state` tells.
- It ignores that display's pan and zoom, is drawn at the window's own size
  above every canvas window, and is drawn on no other display. At a zoom other
  than 1 its picture therefore changes size when it is pinned or unpinned; its
  top-left corner stays where it was.
- It is not on the canvas, so it is in no canvas screenshot, as upstream
  documents: `msg screenshot` of the view, of `all` or of a region never shows
  it, whatever is on the screen. `msg screenshot window --id N` captures it
  alone.
- The move binding drags it in screen space (⌥ left drag by default; ⌥⇧
  left drag, the cluster move, does the same, a pinned window having no
  cluster). The press raises and focuses it first, as upstream's does. The
  window follows the pointer point for point whatever the
  zoom, as upstream's pinned move does. Nothing snaps, the canvas does not
  pan when the pointer reaches an edge, and the frame is not held on the
  display: it can be dragged partly off it, never wholly, because the point
  it was taken by stays on a display, as upstream's confined cursor keeps it.
  A pointer outside the panel of a `--windowed`
  run counts as at the nearest point of the display's edge. Upstream holds
  the cursor itself there; macOS's cursor goes on, so it has to come back to
  the edge before the window leaves it again. Dragged onto another display
  it becomes that display's pinned window. The new place is saved at the
  release. The drag is the same below `[zoom] interact_min`: a pinned window
  is never a pick target, and it moves by the pointer's own distance at any
  zoom.
- The trackpad move gesture drags it the same way: a three-finger double-tap
  and drag over it (or whatever `[gestures]` binds to `move-window` or
  `move-snapped-windows`) moves it point for point with the fingers and
  focuses and raises it first, as upstream's gesture does. The gesture's
  pointer stays on the display it began on, so a gesture does not carry a
  pinned window to another display.
- It is not resized: a resize binding pressed on it raises and focuses it,
  as upstream's press does, gives the note "A
  screen-pinned window is not resized: unpin it first
  (toggle-pin-to-screen)" and goes no further. `nudge-window` and
  `move-to-bookmark` pass it over, and `msg move X Y` and `msg resize W H`
  answer upstream's refusals (reading either still works).
- It takes no part in `zoom-to-fit`, snapping, cluster moves or `auto`
  placement, and leaves the focus history while pinned. A click still goes to
  its application. Closing a window never moves the focus onto a pinned
  window, and closing a pinned window gives the focus to the most recent
  ordinary window in view without moving the camera.
- `msg state` lists it under `pinned` with its display and the `position` and
  `size` a `pinned_to_screen` rule would take, so the numbers paste into a
  rule.
- The pin is saved with the window's slot. A window that takes its slot back
  at the next launch is pinned where it was, moved inward if the display is
  now too small for that place. A slot whose window is gone is dropped or
  becomes a stand-in as before, and a stand-in is back on the canvas where the
  pin showed it.
- A screen change (a display connected, disconnected or resized) and Return
  to desktop followed by Open canvas both rebuild every panel. A pin whose
  display is still there afterwards, at the size it had, stays exactly where
  it was. If the display came back at another size the pin is moved inward
  until the whole frame is on it. If the display is gone the pin moves to the
  first display left, keeping its place as far as the frame fits, and it
  stays there when the old display returns. The shell tells the controller
  that every display is registered (`outputs_settled`) at the end of
  `openPanels`; the controller moves a pin off a missing display only then.

`move-to-bookmark NAME` (no default key) centres the focused window's frame on
that bookmark and raises it; a focused placeholder moves in place. An unset
name, a widget and a pinned window are passed over without an error.

**Navigation, clicks, gestures and displays.** Everything else that acts on
"the window" treats a widget and a pinned window as upstream does. All of it
is the controller's rule
([RULES.md](../../crates/desktop/RULES.md#navigation-activation-gestures-and-outputs)),
covered by its scenarios and not run in the app with a live window:

- `center-window`, `center-nearest`, `focus-center` and Option-Tab pick canvas
  windows only. With a widget or a pinned window focused, `center-window`
  centres the canvas window nearest the middle of the view; `center-nearest`
  does not start its search from a focused pinned window; `focus-center` over
  a pinned window takes the canvas window beneath it, and over a widget alone
  does nothing.
- A click focuses a widget or a pinned window and asks for its native focus
  like any click. Neither enters the most-recently-focused order, also when
  that focus is confirmed, or followed from outside the canvas. No completed
  click (`auto_navigate_on_click`) and no followed native focus flies a camera
  to one.
- `send-to-output <direction>` leaves a focused widget where it is, and moves
  a focused pinned window's pin to the display on that side: the same place
  on that screen, moved inward until the whole frame is on it.
- A three-finger move swipe (a tap, then the swipe) over a widget pans the
  canvas, as upstream's falls back to a pan, a pinned widget included. Over a
  pinned window it moves that window about its display's screen, as above.
  The resize swipe [resizes a canvas window](#resizing-a-window-with-the-pointer) at the controller and is claimed
  and inert over a pinned one; over a widget it pans. A window
  that becomes a widget while a move swipe holds it is let go.
- A hot corner or a gesture bound to `toggle-pin-to-screen` or
  `move-to-bookmark` runs it as the key does: an open Option-Tab cycle ends
  first and a drifting view stops.
- `msg subscribe` carries `pinned` and `is_widget` in every State it prints.

**Known limits**, from reading the code:

- `toggle-pin-to-screen`, `msg pin` and `msg opacity` act on a window with a
  live source only. A placeholder answers `stand-ins can't be pinned` (and
  `no window with id N` for `opacity`), a saved pin that is still waiting for
  its window included, which `msg state` nevertheless lists under `pinned`. In
  a run that manages no window (no Screen Recording access, or `--manual`) such
  a pin stays on its placeholder until a window is bound to it from the
  chooser.
- A pinned window cannot be resized: the move binding's pointer drag and the
  move gesture move it, and that is all. Upstream's resize binding, its
  resize gesture and its title bar also act on the pinned window in screen
  space; here a resize press raises and focuses the window and stops there
  with a note, the resize swipe over one is
  claimed and does nothing, and there is no compositor title bar to
  drag.
- Nothing marks a widget on screen. Upstream's dot marks a pinned window in a
  title bar the compositor draws, which a Mac window has only under a
  `decoration = "server"` rule: a pinned window under its own title bar shows
  none.
- A rule's opacity fades the window's picture on the canvas, not the
  application's own window on the desktop. The compositor multiplies the
  content, the border and the shadow by it, each by itself, as upstream does.
  Probe, demo and owned-fixture runs fade a layer tile instead.
- A window that already has a saved slot ignores a `position` or
  `pinned_to_screen` rule written since: pin it once by hand and the pin is
  saved.
- A pin made by hand may leave part of the window off its display, as
  upstream's may; at the next launch, or when that display changes size, it
  is moved until the whole frame is on.
- An opacity set with `msg opacity` lasts until the window is gone and is not
  saved. A widget moved with `msg move` is back at its rule's `position` at
  the next launch.
- A rule that places a frame outside the 32-bit integer range refuses the
  window (`window geometry exceeds integer range`), and it is not offered
  again until it has left the screen and come back.
- Widgets refuse pointer resizing. Screen-pinned windows use the current
  screen-space readback transaction; window rules can request their native size.

### Passing keys and presses to an application

Upstream's `pass_keys` and `pass_mouse` hand bindings of the canvas to a
window's application, for a game, a remote desktop or an editor that wants the
same chords. The decision is the controller's
([RULES.md](../../crates/desktop/RULES.md#pass-rules)); the shell only stops
claiming the event. **Nothing is posted, re-sent or injected for either**: a
passed key is delivered by macOS, a passed press or scroll by the path that
already forwards every unbound one. **None of it has been run with a real
window, and no key was pressed**:
[what was run](#what-was-run-for-the-pass-rules-and-the-pinned-drag).

```toml
[[window_rules]]
app_id = "com.example.game"
pass_keys = true                 # every key binding, while it is focused
pass_mouse = ["alt+left"]        # ⌥-drag inside it is the game's, not a window move

[[window_rules]]
app_id = "com.example.editor"
pass_keys = ["mod+q", "ctrl+shift+Left"]
```

**`pass_keys`.** Infinify holds its key bindings as global hot keys, which
macOS takes from every application. While the focused window's rule passes a
binding, that chord is not a registered hot key, so macOS delivers it to the
frontmost application like any key Infinify never bound. When the focus moves
to a window without the rule, to a placeholder or to nothing, the chords are
registered again.

- `true` passes every key binding; a list passes the bindings on those
  combos, written in the grammar of the `[keybindings]` table, and the rest
  stay Infinify's. Rules merge as upstream merges them: lists are joined, and
  `true` in any matching rule wins.
- **⌃⌥Esc and `quit` are never passed**, whatever the rule says: they are the
  ways out of the canvas, in the place of upstream's VT switch, the one thing
  it never passes. Everything else is, Option-Tab and ⌃⌥T included. With
  `pass_keys = true` the way back to the bindings is to focus something else:
  click another window, or click empty canvas, which unfocuses.
- The window must hold the keyboard, not only the canvas's focus: its rule
  counts once macOS has confirmed its native focus (or, with
  `--no-native-focus` or without Accessibility access, once the request has
  been answered without one). While a focus request for another window is
  under way, after one failed, and after the focus went to an application
  outside the canvas, nothing is passed. A request for the window macOS last
  reported as focused changes nothing: that window still has the keyboard,
  and its rule goes on counting whether the request succeeds or fails.
- With `focus_follows_mouse` a window focused by the pointer passing over it
  counts the same way: once macOS has confirmed its focus, by the answer to
  the request or by the report that follows it. The window the pointer left
  stops passing at once. The chords are compared at the redraw every such
  change ends in; nothing polls for it.
- A chord that is being held when its binding becomes passed stays a binding,
  repeat included, until it is released, as upstream keeps a key it
  intercepted until its release.
- A chord macOS will not give back when it is registered again is named on
  the status line ("Shortcut unavailable: …") and on stderr.
- A `--windowed` run registers no global hot keys, so it has none to pass.

**`pass_mouse`.** Every press and every scroll over a live window asks the
controller for its binding, and now says which window the pointer is over.
Where that window's rule claims the trigger, the binding is not run and the
event is the application's, exactly as an unbound one: a press focuses the
window and is forwarded to it, a scroll is forwarded.

- The window that decides is the one **under the pointer**, focused or not, a
  pinned window or a widget included. A placeholder claims nothing, and
  nothing is claimed over empty canvas.
- Below `[zoom] interact_min`
  ([pick mode](#pointer-motion-sloppy-focus-and-pick-mode)) a window on the
  canvas claims nothing, as upstream: it is a pick target there and no press
  or scroll reaches its application anyway, so ⌥-drag moves it and a bound
  scroll pans or zooms. A pinned window keeps its claims on presses, because
  it stays usable there, and loses its claims on scrolls and wheel notches
  while its display is below the threshold.
- `true` claims every mouse binding over the window, the ⌃⌥ pan and zoom
  included; a list claims those combos (`"alt+left"`, `"mod+wheel-scroll"`,
  `"mod+trackpad-scroll"`, `"mod+wheel-up"`). A mouse wheel and a two-finger
  scroll are claimed under their own names, and a wheel notch under its own
  too: listing `"mod+wheel-up"` gives the application the notch binding and
  leaves a `mod+wheel-scroll` zoom running.
- For 150 ms after a two-finger scroll has panned, scrolls stay with the
  canvas and nothing is claimed, as upstream.
- Trackpad gestures of three or more fingers and the pinch ask no claim, as
  upstream's gesture dispatch asks none.
- Forwarding needs Accessibility access, as every forwarded press does.

**Known limits**, from reading the code:

- The hot keys follow the controller's idea of which window holds the
  keyboard. The passed chord goes to whichever application macOS has in
  front. With `--no-native-focus`, or without Accessibility access, the two
  can differ: the chords are then released while another application is in
  front, and that application gets them.
- A list names a binding by its combo text. Two spellings can be one physical
  chord (`mod+q` and `ctrl+alt+q` are both ⌃⌥Q under `--super ctrl+alt`);
  only the spelling of the binding that holds the chord passes it. Upstream
  compares modifier state and has no such choice.
- When the focus leaves a passing window while a passed chord is still held,
  the hot key is registered again at once. Whether macOS then fires the
  binding for the key's auto-repeat is not known.
- A widget's `pass_mouse` holds below `[zoom] interact_min` too, where
  upstream drops it with every other claim but a pinned window's presses:
  the lookup is not told which display the pointer is on, and a widget that
  is not pinned is on no display of its own.
- A mouse wheel reports whole lines, several for a fast turn, so a notch's
  action runs once per line; upstream counts real notches and adds up the
  fractions of a high-resolution wheel.
- macOS turns a mouse wheel sideways while Shift is held: the turn arrives as
  a horizontal one. A notch binding with Shift in it (`mod+shift+wheel-up`)
  still fires, because the shell reads the notch back from the horizontal
  turn; a sideways wheel turned with Shift held looks the same and fires it
  too, which upstream's does not. A wheel `zoom` or `pan-viewport` binding
  with Shift in it is not put right: the zoom does nothing and the pan goes
  sideways. None of this was tried with a wheel.
- Media keys are not registered by the shell at all, so `pass_keys` changes
  nothing for them.

### `layer_order`

`layer_order = N` in a rule is read, kept with the window and ignored: no
window is drawn or clicked above another because of it. That is what upstream
does with the field for a window. It orders layer-shell surfaces (panels and
overlays) and its documentation says "Ignored for regular windows"; a Mac has
no layer surfaces, and every window here is a regular one. Windows stack by
what was raised last, widgets below the canvas windows and pinned windows
above them. `Infinify msg` has no view of a rule; the controller's snapshot
lists the value with the window and names the field among those that change
nothing.

### What was run for rules, widgets and pins

On 2026-10-10 (macOS 27.2, Apple Silicon), on the build with the review fixes:
`./scripts/build-app.sh`; the controller scenarios in
`crates/desktop/tests/rules_flow.rs` (16, on two outputs) with the lifecycle,
config, IPC, view-action, controller, navigation and focus-cycle modules,
through the exported C ABI with synthetic observations; and one launch of the
built, ad-hoc signed app as `--windowed 1100x700` on a private scene, config
and socket, driven through `Infinify msg` for six seconds. It repeats a first
launch of 2026-10-09. Nothing from it is saved as evidence. The launch had **no
Screen Recording and no Accessibility grant, so no window was captured**: the
scene held three seeded placeholders with a bundle identifier
(`org.example.seed`) that belongs to no application.

The scene came from a throwaway program that drove this build's controller in
process, not the app: it attached three synthetic sources on two outputs named
`windowed` and `away`, pinned "Terminal" on `away` at the point (100, 100)
there, pinned "Browser" on `windowed` (first with `toggle-pin-to-screen`, last
with a `Pin` write, which is the pin that was saved) and saved. In that
program, on a window with a (synthetic) live source: the pin read `[60, 10]`
from the output's centre before and after `pan-viewport right`; unpinned after
the pan the window's canvas centre was 2110 10 where it had been 2010 10
before the pin, the camera having moved 100; `Pin` set to true and false
answered each value; `Opacity` read 1, answered 0.5 to a write and read 0.5
back, and 1.5 was refused with `opacity must be between 0.0 and 1.0`.

Observed in the app, each read back over the socket:

- Both saved pins were read back, and the one whose display never appeared
  had moved: the app opened one panel, `windowed`, and its first `msg state`
  listed placeholder 1 under `windows` and, under `pinned`, `windowed #3
  org.example.seed [-170, 28] 560x380 "Terminal"` and `windowed #2
  org.example.seed [60, 10] 900x600 "Browser"`. `[-170, 28]` is the point
  (100, 100) on a 1100x636 output. No discovery pass ran in that launch, so
  the move is the `outputs_settled` call at the end of `openPanels`. The file
  saved at exit held that pin on the `windowed` output at `[100, 100]`.
- Both entries were the same after `pan-viewport right` (camera 550 to 650),
  after `toggle-pin-to-screen` and after `move-to-bookmark` with placeholder
  2 focused. `msg move --id 2` and `msg move --id 3`, the canvas points under
  the pins, followed the camera meanwhile: 610 -308 and 380 -290, then
  710 -308 and 480 -290. `msg move --id 1`, a canvas slot, read 520 -360 both
  times.
- `msg move --id 2 10 10`: `this window has no canvas position to move: it is
  pinned, fullscreen, or not on screen yet`. `msg resize --id 2 800 600`: `this
  window has no canvas size to set: it is pinned, fullscreen, a widget, or not
  on screen yet`. Both exit 1; `msg resize --id 2` read 900 600.
- On the placeholders: `msg pin --id N`, with and without a value, answered
  `stand-ins can't be pinned`, for the pinned ones too; `msg opacity --id N`,
  with and without a value, answered `no window with id N`; `msg action
  toggle-pin-to-screen` with a placeholder focused answered `ok` and changed
  nothing.
- The config named two rules that match the placeholders' titles (`widget` for
  "Notes", `pinned_to_screen` with a `position` for "Term*"). Neither changed
  anything: no window reached the canvas in that run, `state` kept `is_widget`
  false, and "Terminal" stayed where its saved pin put it.
- `msg bookmark 1 300 200`, then `msg action move-to-bookmark 1` with
  placeholder 1 focused: `msg move --id 1` read 300 200. With an unset name,
  and with a pinned placeholder focused: `ok`, nothing moved.
- `decoration = "fancy"` in a rule printed upstream's `config: unknown
  decoration mode 'fancy', falling through to default_mode` on stderr at
  launch. A rule key the grammar lacks (`sticky = true`), appended while the
  app ran and followed by `msg action reload-config`, printed upstream's TOML
  error (``unknown field `sticky`, expected one of …``) twice, the file watch
  and the action each loading the file, and the app went on answering.
- SIGTERM: exit status 0, socket removed.

Not run, because it needs a captured window: a rule matching a real
application and placing, pinning or making a widget of its window; a pin or an
unpin of a live window in the app, by ⌃⌥T or by `msg`; `msg opacity` on a live
window; a widget of any kind; the close of a window beside a widget or a
pinned window, and of a pinned window or a widget itself; a pinned window that
returns to its slot at launch, or one whose slot becomes a stand-in. Not run,
because it needs a second display or a click in the panel: a screen change,
and Return to desktop followed by Open canvas, with a pin in place; those two
paths are covered by the controller scenario that replays the shell's command
order, and by reading `main.m`. No zoom was run this time; the first launch
read the pinned entry unchanged at zoom 0.5.
Not looked at: anything drawn, so neither the order of the tiles that build
drew (widgets below, pinned windows on top) nor a tile's opacity, nor the two
status notes. The compositor has drawn the canvas since:
[What was run for rules and rendering together](#what-was-run-for-rules-and-rendering-together)
has what was seen of the layers, the pinned space and an opacity, and where.
No pointer press was made, so the refusal of a move or resize binding on a
widget or a pinned window, the bound press that now reaches a widget's
application as a click, and a plain click reaching either one's application,
are compiled and read only, like ⌃⌥T itself.

### What was run for the pass rules and the pinned drag

**`pass_keys`, `pass_mouse` and the pinned drag ran only as
controller scenarios through the exported C ABI. No key was pressed, no hot
key was seen being unregistered or registered again, no real window received
a passed key, press or scroll, and no pinned window followed a real
pointer.** The shell's side (`hotkeys.m`, and four hooks in `main.m`) was
compiled and read, nothing more. This is the record of the day the two were
first built together;
[what was run once the pointer policy, window sizing and effects were built in](#what-was-run-for-the-pass-rules-with-everything-else-built-in)
follows it. On that first build the controller also ranked windows by
`layer_order` and the shell asked no wheel notch; both have changed since.

On 2026-10-10 (macOS 27.2, Apple Silicon), with the controller and the shell
built together for the first time:

- `./scripts/build-app.sh`: built and ad-hoc signed, every shell file under
  `-Wall -Wextra -Werror`.
- `cargo fmt -p driftwm-desktop -- --check` and `cargo clippy -p
  driftwm-desktop --all-targets -- -D warnings`: clean.
- The controller scenarios, through the exported C ABI with synthetic
  observations: `passthrough_flow` (16; 14 before the review fixes below),
  `rules_flow` (21), `config_flow` (12), `gesture_flow` (21),
  `navigation_actions_flow` (12), `lifecycle_flow` (25), `ipc_flow` (8) and
  `controller_flow` (4), all passing. What
  `passthrough_flow` covers is listed in
  [RULES.md](../../crates/desktop/RULES.md#verification-boundary).
- `tests/e2e/desktop-navigation.sh` was not run: the navigation coordinator
  and its regression program were not touched.
- One launch of the built app as `--windowed 1100x700` on a private scene,
  config and socket, driven through `Infinify msg` for under ten seconds.
  Nothing from it is saved as evidence. It had **no Screen Recording access**
  (its one line on stderr at launch said so), so no window was managed and
  the scene's three windows were placeholders with a bundle identifier
  (`org.example.seed`) that belongs to no application.
- After review fixes the same day, all in the controller (a pinned drag's
  pointer is held on a display, a pinned placeholder keeps its drag when its
  window is adopted, and the drag ends when a discovery pass keeps the
  placeholder), the build, the format and lint checks and the eight test
  modules were run again, and the app was launched once more the same way
  for three seconds: the same scene recipe and configs, and the same
  observations as below, the in-process read included. No shell file changed
  for them.

The scene came from a throwaway program driving this build's controller in
process: three synthetic sources, the first ("Notes") pinned with
`toggle-pin-to-screen` on an output named `seed` at the output-local point
(200, 150), and saved. The config held two rules: `app_id =
"org.example.seed"` with `pass_keys = true`, `pass_mouse = ["alt+left"]` and
`layer_order = 2`, and `title = "Terminal"` with `pass_keys = ["mod+q",
"ctrl+shift+Left"]`, `pass_mouse = true` and `layer_order = -1`.

Observed in the app, over the socket:

- The config loaded at launch with no warning on stderr, and `msg action
  reload-config` answered `ok` and printed nothing.
- With `pass_keys = ["mod+q", "mod+nosuchkey"]` and `pass_mouse =
  ["alt+left", "alt+banana"]` written to the file and reloaded, stderr had
  upstream's warnings, `config: pass_keys invalid key combo 'mod+nosuchkey':
  unknown keysym: nosuchkey` and `config: pass_mouse invalid mouse combo
  'alt+banana': unknown mouse trigger: banana`, each twice (the file watch
  and the action each loaded the file), and the app went on answering. The
  first config written back and reloaded printed nothing.
- `msg state` listed `windowed #1 org.example.seed [-30, -42] 640x420
  "Notes"` under `pinned`, and placeholders 2 and 3 under `windows`. The
  `seed` output never appeared, so the pin had moved to the one panel, where
  `[-30, -42]` is the point (200, 150) on its 1100x636 output. The entry was
  the same after `pan-viewport right` (camera 550 to 650). `msg pin --id 1`
  answered `stand-ins can't be pinned`. The file saved at exit held the pin
  on `windowed` at `[200, 150]`.
- `msg --json state` has no `pass_keys` field: `state` is upstream's shape,
  and the controller's snapshot is not reachable over the socket. It showed
  the two placeholders under `windows` as `suspended` and not focused.
- SIGTERM: exit status 0, socket removed.

Read from the controller in process, with the same scene file and config (a
throwaway program, not the app): `load_config` answered no error and no
warning; each of the three windows had no source and no `rule`;
`snapshot.pass_keys` was `null` with each of them focused in turn; and
`mouse_binding` for ⌥-left in the window context, naming each of them as the
window under the pointer, answered the `move_window` binding, the same reply
as without a window. That is the rule working as written, not a failure to
load it: a rule is resolved for a window with a live source only, and a
placeholder has none, so it passes nothing and claims nothing, as upstream
skips its stand-ins.

Not run, because it needs a captured window, a key or a pointer:

- **`pass_keys` in the app at all.** The one launch was windowed, which
  registers no global hot keys, and no window in it had a rule, so the
  shell's `-pass:` was only ever handed "nothing passed". A hot key being
  unregistered when a passing window takes the focus and registered again
  when it leaves, the exit chord and `quit` staying registered, the held-key
  deferral, a reload or an input-source change while a passing window is
  focused, and above all the chord arriving in the application: none of it
  has been observed.
- **`pass_mouse` in the app.** No press or scroll was made in the panel, so
  neither a claimed press reaching an application nor a claimed scroll has
  been seen. The lookup with a window ran in the controller scenarios and in
  the in-process read above only.
- **The pinned drag in the app.** A drag cannot be driven over `msg`. The
  drag ran in controller scenarios (at zoom 0.5, off an output's corners,
  across two outputs, with the pointer on no output and in the strip above
  one, under a close, and on a placeholder through its adoption); no pointer
  moved a pinned window, and the resize note was not seen. That the shell
  goes on reporting a drag while the pointer is over the toolbar strip or
  outside a windowed panel, which is where the controller holds it, was read
  in `main.m`, not seen.

### What was run for the pass rules with everything else built in

Historical evidence: invocations of `--experimental-native-resize` in this
subsection refer to the mode removed on 2026-10-12.

On 2026-10-10 (macOS 27.2, Apple Silicon) the pass rules and the pinned drag
were merged into the build that has the pointer policy, the sizing actions
and the effects. Three things changed in that merge beyond the join itself:
`layer_order` orders nothing again (above), the shell asks the wheel-notch
lookup, and the trackpad move gesture moves a pinned window. **None of it
has been run with a real window, a key, a wheel or a trackpad**; what follows
is what was run.

- `./scripts/build-app.sh`: built and ad-hoc signed, every shell file under
  `-Wall -Wextra -Werror`.
- `cargo fmt -p driftwm-desktop -- --check` and `cargo clippy -p
  driftwm-desktop --all-targets -- -D warnings`: clean.
- The controller scenarios, through the exported C ABI with synthetic
  observations, all passing: `passthrough_flow` (19), `rules_flow` (22),
  `pointer_flow` (16), `sizes_flow` (30), `effects_flow` (5), `render_flow`
  (7), `gesture_flow` (21), `motion_flow` (9), `platform_actions_flow` (11),
  `navigation_actions_flow` (12), `lifecycle_flow` (25), `config_flow` (12),
  `ipc_flow` (8), `controller_flow` (4), `navigation_flow` (5) and
  `focus_cycle_flow` (5); and, because the one place a drag is installed
  changed, `native_resize_flow` (25) and `view_actions_flow` (2).
- `./tests/e2e/desktop-navigation.sh`: PASS.
- Read from the controller library by a throwaway program, with upstream's
  built-in defaults: 57 key bindings, 45 on Mac keys, 8 on media keys macOS
  handles itself and 4 on keys a Mac lacks; of the 45, 42 run without
  `--experimental-native-resize` and 44 with it; 44 are `passable`, every one
  but `quit`, and no binding holds the exit chord.
- Two launches of the built app as `--windowed 1100x700` on a private scene,
  config and socket, driven through `Infinify msg`, each under 30 seconds.
  Nothing from them is saved as evidence. Both had **no Screen Recording
  access** (the one line on stderr at launch said so), so no window was
  managed and the scene's three windows were placeholders with a bundle
  identifier (`org.example.seed`) that belongs to no application.

The config held one rule, `app_id = "org.example.seed"` with `pass_keys =
true`, `pass_mouse = ["alt+left"]` and `layer_order = 2`, and
`"mod+wheel-up" = "zoom-in"` under `[mouse.anywhere]`.

Observed in the first launch, over the socket, on three seeded placeholders:

- The config loaded with nothing on stderr but the Screen Recording line, and
  `msg action reload-config` answered `ok` and printed nothing.
- `msg state`: camera `550 -318`, zoom 1, three windows, `pinned 0`.
- `msg action center-nearest right`: `ok`; the camera settled at `1950 -0`
  with `msg focus` on `#2 org.example.seed` ("Browser", whose `msg move --id
  2` read `1950 0`). `msg action pan-viewport right`: camera `2050 -0`.
- `msg action zoom-to-fit`: camera `750 -390`, zoom `0.28484848484848485`;
  again: back to `2050 -0` at zoom 1. `msg action zoom-to-fit-snapped`: `ok`,
  camera `1950 -0`, zoom `0.7933333333333333`; again: back.
- `msg screenshot -o FILE`: a 1100x636 picture, looked at: the dot grid on
  black and the "Browser" stand-in, a dark rounded 900x600 panel with its
  close glyph and the bundle identifier, against the left edge.
- With `pass_keys = ["mod+q", "mod+nosuchkey"]` and `pass_mouse =
  ["alt+left", "alt+banana"]` written to the file and reloaded, stderr had
  upstream's `config: pass_keys invalid key combo 'mod+nosuchkey': unknown
  keysym: nosuchkey` and `config: pass_mouse invalid mouse combo
  'alt+banana': unknown mouse trigger: banana`, each twice (the file watch
  and the action each loaded the file), and the app went on answering.
- SIGTERM: exit status 0, socket removed.

The second launch read a scene that a throwaway program had written through
this build's controller in process: the same three windows with synthetic
sources, "Notes" pinned with a `Pin` write on an output named `windowed` at
the point (200, 150), then dragged by `begin_drag`, `gesture_to` with a
screen displacement of (40, 25) and `end_gesture`, which is the pinned drag,
to (240, 175), and saved. In the app:

- `msg state` listed `windowed #1 org.example.seed [10, -67] 640x420 "Notes"`
  under `pinned` and the other two under `windows`; `[10, -67]` is the point
  (240, 175) on the 1100x636 output. The entry was the same after
  `pan-viewport right` (camera 550 to 650).
- `msg pin --id 1`: `stand-ins can't be pinned`, exit 1.
- `msg screenshot window --id 1 -o FILE`: a 640x420 picture of that
  placeholder alone, looked at.
- SIGTERM: exit status 0, socket removed; the file saved at exit held the pin
  at `[240, 175]`.

Read from the controller in process, with the first launch's scene and config
(a throwaway program, not the app): `load_config` answered no error and no
warning; none of the three windows had a source or a `rule`;
`snapshot.pass_keys` was `null` with each focused in turn; `mouse_binding`
for ⌥-left in the window context, naming each as the window under the
pointer, answered the `move_window` binding; `wheel_up` under ⌃⌥ answered
the `zoom-in` action bound to `mod+wheel-up`, on a window and on the canvas,
`wheel_down` nothing, and `scroll` from a wheel under ⌃⌥ still the zoom; and
one snapshot carried `pass_keys`, `lifecycle_events`, each output's `pick`
and each window's `mode` together. The seeded windows are stand-ins, so no
rule applied to any of them, in the app or in process: that is the rule for
a window without a client, not a failure to load it.

Not driven, because `msg` has no verb for it or because it needs a captured
window, a key, a wheel or a trackpad:

- **Any key.** A windowed run registers no global hot keys, so the shell's
  `-pass:` was only ever handed "nothing passed". A hot key leaving when a
  passing window takes the focus, by a click or by the pointer passing over
  it, and returning when it leaves, has not been observed.
- **Any press, scroll or wheel notch.** A claimed press or scroll reaching
  an application, the claim being dropped over a pick target and kept by a
  pinned window, and a notch binding running its action once per line were
  not seen: the notch site in `-scroll:` was compiled and read only.
- **A pinned window moved in the app**, by ⌥-drag or by the three-finger
  move swipe, and the swipe focusing and raising it.
- **Pick mode, hover focus, a size transaction and a window animation** in
  the app at all: those are the earlier sections' to report, and nothing
  here adds to them.

## Rendering

In a normal run, `--windowed` included, the canvas is drawn the way DriftWM
draws it. Each output is one Metal layer that draws its whole frame: the
`[background]` (the default dot grid, a shader, a tile, a wallpaper or none),
the outlines of the other outputs' viewports from `[output.outline]`, and every
window bottom to top with upstream's shadow, border, corner clip and opacity
from `[decorations]` and the rule it reached the canvas with, the focused one
with `border_color_focused`: widgets first, then the canvas windows, then the
windows pinned to that display's screen
([Window rules](#window-rules-widgets-and-pinned-windows)). A window without a live source is a compositor-drawn
stand-in: title bar with its close glyph, body, and the application's name,
followed by ` launching…` while a relaunch is pending.

What changes on screen against earlier builds: the canvas is DriftWM's dot grid
on black (or whatever `[background]` names) where it was a flat dark blue; a
captured window has a soft shadow and its corners are clipped to
`[decorations] corner_radius`, 10 by default; a placeholder is a dark rounded
panel with a close glyph and the application's name where it was a grey tile
reading "Detached window N"; and `[decorations]`, `[background]`,
`[output.outline]` and the decoration keys of `[[window_rules]]` are applied
([Settings](#settings)): the three tables on the next reload of the config
file, a rule to the windows that reach the canvas after it, since a window
keeps the rule it arrived with. Keys, pointer
gestures, hit testing, input forwarding and every command are as they were.
All of this is what the code draws and what `msg screenshot` showed for
stand-ins; [what was run](#what-was-run-for-rendering) says what has not been
seen, a captured window and the panel on a display among it.

The drawing code is the compositor port in `compositor.{h,m}` and
`background.{h,m}`: upstream's shaders and frame composition translated to
Metal, built and checked outside this repository and carried in unchanged
apart from one provenance line each. Its headers name the upstream files it
derives from, and its own notes came with it: where those four files say
`NOTES.md`, the compositor's is [COMPOSITOR-NOTES.md](COMPOSITOR-NOTES.md)
(upstream file hashes, the host protocol, every deviation, what was verified
and how) and the background's is [BACKGROUND-NOTES.md](BACKGROUND-NOTES.md).
`canvas-renderer.{h,m}` is the host: it turns the controller's snapshot into
the compositor's frame description. What the snapshot carries is
[`crates/desktop/RENDER.md`](../../crates/desktop/RENDER.md).

- **Frame.** Camera, zoom and size are the output's `camera`, `zoom` and
  `screen_bounds`; the scale is the panel's backing scale. Every element is
  given at its canvas rectangle (`world_rect`), and the compositor subtracts
  the camera itself, as upstream does. No native window geometry is read.
- **Layers.** The controller lists a display's placements bottom to top:
  widgets, canvas windows, pinned windows. A placement that says `widget` goes
  into the compositor's widget layer and one that says `pinned` into its
  pinned layer, a pinned widget with the pinned ones as upstream; the
  compositor draws the three layers in that order and keeps the controller's
  order inside each. A pinned window is the one element not given at a canvas
  rectangle: it is given at the placement's `screen_rect`, less the display's
  origin, in the compositor's pinned space, which draws it at zoom 1 with no
  camera, so it keeps its place and its own size while the canvas pans and
  zooms beneath it. Its canvas rectangle is never projected. Upstream's dot at
  the left of a pinned window's title bar is drawn where the compositor draws
  the bar, that is under a `server` rule only.
- **Opacity.** What the controller reports for a window, a rule's value, one
  set with `msg opacity` or the `[decorations]` default for its focus, is part
  of its decoration and multiplies every pass of the element.
- **Decoration mode.** A captured Mac window already draws its own title bar,
  so it is decorated as upstream decorates a client-side-decorated window: no
  compositor title bar; border, shadow, corner clip and opacity around the
  whole captured frame. A window rule can still ask for `server` (a second,
  compositor-drawn bar above the frame), `minimal` or `none`.
- **Coverage.** Upstream's `DrawnChrome` rule is applied per output: a window
  whose frame exactly covers the output is drawn square and without shadow,
  one that overhangs it without border as well. The usable area is the whole
  output, which in a normal run is the whole display. A pinned
  window is judged where it is drawn, at its screen rectangle. A window's
  blur is not subject to it.
- **Stand-ins.** A stand-in's bar and body together take the window's
  rectangle (upstream's `standin_body_rect` for a client-decorated window). It
  wears the global `[decorations]` table alone, no window rule, and it is
  always opaque, as upstream's: `opacity` and `opacity_focused` dim windows,
  not stand-ins. Its label is
  the application's name as the Finder shows it, looked up once from the
  bundle identifier; an application that is not installed shows the
  identifier. The old "Detached window" hint text is gone; ⌃⌥-click still
  dismisses a placeholder while no binding claims that press, and the
  placeholder now shrinks and fades as any dismissed stand-in does
  ([below](#blur-window-animations-and-the-error-bar)). A placeholder
  whose slot still holds a saved pin is drawn as a stand-in at the pin's
  rectangle, in the pinned layer.
- **Streams.** A source keeps the latest pixel buffer of its stream and the
  compositor samples it; nothing is enqueued into a display layer. A new frame
  redraws only the outputs that show that window, once per refresh of the
  display however many frames arrived in it (Frame pacing, below), and
  nothing is drawn while nothing changes. A complete frame whose
  `SCStreamFrameInfoDirtyRects` is there and empty changed nothing: it is
  not kept and redraws nothing, once the window has a picture. A frame that
  carries no such list is kept as before, and so are the first complete frame
  of a stream that was just started or given a new size and a frame whose
  size is not the kept picture's: the picture held then is from before the
  stream stopped or the window was resized. Not observed: whether
  ScreenCaptureKit delivers such frames at all could not be seen from a
  process without Screen Recording access.
  Streams are configured with `colorSpaceName = sRGB`, which the compositor's
  colour handling requires, and a queue depth of 5 instead of 3, because the
  compositor holds the current buffer and briefly the one before it. When
  capture on demand stops a stream, the last picture stays, so a window whose
  placement returns is not blank until its stream delivers again. A window
  that has never delivered a frame is the chrome background colour inside its
  border and shadow.
- **Frame pacing.** The scene is gone through once per refresh of the
  display, by the [frame timer](#rendering) below, and at no other moment
  while that timer runs. Every stream hands its frames to the main queue,
  each on a turn of its own and at a moment of its own, and until this was
  measured each such turn drew the scene: four windows changing at 120 Hz
  drew it 239 times a second on a 120 Hz display, of which the display
  showed 120, and each draw waited on the main thread for its command buffer
  to be scheduled, 3.3 ms on average: 0.78 s of every second in which the
  main thread, which also serves input, hot keys, Accessibility and the
  socket, was not available. Now a picture, an animation's step or a decoded
  chunk only marks its outputs and asks for a frame; the timer's frame
  describes the camera, marks the animations and then flushes once, so a
  camera frame and a window's picture of the same refresh are one draw with
  both in it. A description made outside a frame (the idle poll, a socket
  command, a pan from the trackpad) is left to the next frame too while the
  timer is running, and is drawn at once when it is not, as before. Drawn at
  once whatever the timer does: a frame whose output is new or whose layer
  changed its place, size or scale, which is presented inside the
  transaction that moves the layer (the launch's first frame, a panel
  resized, the panels rebuilt after a display change); and everything while
  no frame is coming: the quit-pending loop, and a timer that has not called
  back for a quarter of a second because its display is asleep. A timer
  silent for a second is replaced by the next change that wants one.
  Only the timer's own flush leaves a frame to its command buffer to
  present at the refresh being served, with nothing waiting for it
  (`presentsWithTransaction` is set per frame). Every frame drawn at once is
  presented inside the transaction, as all were before: no display link is
  known to be refreshing then, and a drawable left to a refresh that does
  not come would not return to the layer's pool. A frame that got no
  drawable stays owed and is tried again by the next flush. While the timer
  serves no camera motion its frames tell cursor edge pan of the pointer
  only when it has moved; the idle poll, which goes on beside it, reports a
  pointer at rest. The
  same load after the change: 119 draws a second, all shown, 0.14 ms each
  (`tests/e2e/scoped-render-bench.sh`, [below](#managing-only-named-processes)).
  What that run cannot say is in the same place.
- **Config reload.** The background program, the chrome style, the outline
  settings, `[effects]` and the error bar's messages are rebuilt when the
  snapshot's `render.revision` changes and at no other time. The controller
  moves it on every config reload it accepts, also
  one that changed nothing, so a shader, tile, wallpaper or texture file
  edited on disk is read again after `msg action reload-config`, the
  `reload-config` binding or a `touch` of the config file, as upstream reads
  it again on every reload. A file that fails to parse changes no table, but
  its message is new to the error bar, so the revision moves once and the same
  tables are built again; the same failure a second time rebuilds nothing. A
  shader that does not compile or a file that is missing falls back as
  upstream does, to the dot grid; the reason is written to stderr, is shown in
  the [error bar](#blur-window-animations-and-the-error-bar) and stays in the
  status line too, until a reload builds a program without one.
- **Autorelease pools.** Metal hands out autoreleased drawables and encoder
  contexts. Each layer update is drawn inside a pool of its own, and the main
  loop of a normal run has one per turn, so a redraw issued from a poll, the
  launch's first frame or the quit-pending loop frees what it made.
- **Animated backgrounds and the frame timer.** There is one frame timer, and
  it runs at the display's refresh rate: a display link
  (`frame-driver.{h,m}`, `-[NSScreen displayLinkWithTarget:selector:]`) of the
  fastest screen a canvas panel is on, so 120 Hz on a ProMotion display and
  60 Hz on a 60 Hz one, where it was an `NSTimer` at 60 Hz whatever the
  display. One link serves every panel, so the controller is ticked once a
  frame however many displays there are. Five things keep it running:
  windows' pictures as their streams deliver them, and for a quarter of a
  second after the last, so that a display link is not made and ended
  between two frames of a video;
  [camera motion](#camera-motion) (a flight, a drift, an edge pan), a shader
  background that reads `u_time`, redrawn at that rate capped by `animate_fps`
  and only while a panel that shows it is open, a background
  [chunk cache](#background-caches) that is still filling, given one frame a
  tick until nothing is pending, and a window that opens or
  leaves (an open or close animation, a stand-in's fade,
  [below](#blur-window-animations-and-the-error-bar)), drawn on every tick.
  It stops when none of the five is left, so the frames of an opening window
  end with its animation, and the link is made when frames are first wanted
  and invalidated when they stop being: no display callback is asked for
  while nothing needs one. While a background or an animation alone keeps it
  running it ticks no camera and watches no hot corner: the idle poll goes on
  doing both every 80 ms, exactly as when the timer is stopped, and regains
  the display's rate for the camera when it finds motion. A display link
  calls back only while its display refreshes; camera motion it has not
  served for a quarter of a second (a display asleep) is ticked by the poll
  instead, at the poll's pace, so a flight still arrives. The
  pointer's part of a frame is the one thing such a frame still does: the
  waiting [hover](#pointer-motion-sloppy-focus-and-pick-mode) and cursor edge
  pan's pointer report go out with it, since no other timer sends a hover
  while this one runs.
- **Experimental native resize.** A placement that is not settled is drawn
  without content (the placeholder fill), never with a stale frame, and a
  settled one whose kept frame belongs to another observation asks for a new
  frame. A window that is still opening is not drawn at all meanwhile: its
  open animation waits for the size it is owed
  ([below](#blur-window-animations-and-the-error-bar)). The orange handles are Core Animation layers above the compositor
  layer, clipped to the window's visible rectangle as before; a widget and a
  pinned window get none, and no window does on a display in
  [pick mode](#pointer-motion-sloppy-focus-and-pick-mode), where no handle
  takes a press. Because that overlay is above everything the
  compositor draws for the output, a handle whose point lies under a later
  placement on the same output (a pinned window, or a window stacked above the
  focused one) is not drawn, by the test the press already uses to refuse it;
  the layer tiles hid such a handle by their order.
- **Probe, demo and owned-fixture runs** (`--demo*`, `--owned-resize-*`) keep
  the earlier drawing, a clipped `AVSampleBufferDisplayLayer` per placement on
  a flat colour, and their earlier stream configuration, because their recorded
  evidence was made with it. A placement's opacity is the opacity of its tile
  there. They never create a compositor, so they have no blur, no window
  animation and no error bar.

### Blur, window animations and the error bar

DriftWM's visual effects, drawn in a normal run by the same compositor. There
is no new flag, key or command: the effects follow the config file and what
windows do. What the controller reports for them is
[`crates/desktop/EFFECTS.md`](../../crates/desktop/EFFECTS.md); how the
compositor draws them is [COMPOSITOR-NOTES.md](COMPOSITOR-NOTES.md), sections
17 to 25, whose host protocol (section 18) `canvas-renderer.m` follows.
**None of this has been seen in the app's own panel**: it was drawn offscreen
by the app's renderer from this controller's snapshots, and the app was run
through the same events without anyone looking at it
([what was run](#what-was-run-for-effects)).

What changes on screen against earlier builds:

- **Blur.** With `[decorations] blur = true` every window, and with a window
  rule's `blur = true` that window whatever the table says, has what lies
  beneath it frosted: upstream's blur of `[effects] blur_radius` passes (2)
  spread by `blur_strength` (1.1), cut to the window's shape. The frost is
  drawn at full strength under the window and shows only where the window
  lets it through: under one made translucent by `[decorations] opacity` or
  `opacity_focused`, a rule's `opacity` or `msg opacity`, or through content
  that is itself translucent. An opaque window with blur pays for a frost
  nobody sees, as upstream. A stand-in is never frosted, as upstream's. Over
  an animated background the frost is refreshed `animate_blur_fps` times a
  second (20; 0 keeps what it first captured; values above 144 are 144).
- **A window opens.** A window that appears by itself once the launch pass is
  over grows from `[effects] animation_scale` (0.95) to its size and fades in,
  upstream's open animation at `animation_speed` (0.5: about 0.11 seconds;
  nearer 0 is slower, 1 is instant and plays nothing). A widget and a
  `focus_on_open = false` window open the same way. It begins with the first
  picture the window's stream delivers: until then, and for a second at most,
  the window is not drawn at all, where earlier builds showed an empty frame.
  A window whose rule
  names a `size` is asked for that size as it appears
  ([Window sizing actions](#window-sizing-actions)); its opening waits
  until the size request is answered. Its opening waits for it too, as
  upstream's window opens at the size its rule gave it: the second for its
  first picture starts when the resize has been answered, done or refused,
  and a picture that arrives earlier, of the size it is leaving, starts
  nothing. A resize that is never answered holds the window back for ten
  seconds at most.
- **A window closes.** Its last picture, with border and shadow, shrinks to
  `animation_scale` and fades out where it stood, above the other canvas
  windows and below the pinned ones. When the close leaves a stand-in
  (`suspend_on_close`, `suspend-window`) the picture fades in place over the
  stand-in instead. Of several windows closing at once the one that began
  first is on top, as upstream stacks them. A window that was translucent is
  opaque for the length of its close, as upstream's snapshot is.
- **A stand-in leaves.** Dismissed by `close-window`, `suspend-window`,
  `Infinify msg close` or a ⌃⌥-click on it, it shrinks and fades. When the
  window of a relaunch takes its slot, it fades without moving over that
  window, from the window's first picture (a second at most).
- **The error bar.** A problem in the config file, and a background that fell
  back, are written along the bottom of every display: one line of white
  monospace on a black strip 23 points high, the config's message first, then
  the background's, joined by a bullet and cut with an ellipsis where the line
  is longer than the display. The config's message is upstream's:
  `config: failed to read <path>: <reason>`, `config error: <the TOML error>`
  with its several lines run into one, or one warning, the first of them in
  sorted order, followed by ` (+N more)`. It goes when a later load is clean. The bar is a picture only:
  a click on it reaches whatever is beneath. A problem in the config file is
  shown there and nowhere else on screen, as upstream shows it: the status
  line does not repeat it, and stderr has every message of the load, its
  warnings in the same sorted order, so the first line there is the one the
  bar names. A background that fell back is still named in the status line
  as well.

What plays nothing, by upstream's rules or by this port's:

- the windows the launch pass puts on the canvas, a window that takes its own
  saved slot back at any time (a minimized window shown again, a capture that
  recovered), and a window attached from the chooser: none of them opened
  here. Without Screen Recording access or with `--manual` nothing ever opens;
- a close or a dismissal that no display was drawing, a window that never had
  a picture, and everything at `animation_speed = 1`;


Limits the owner will notice or should know of:

- A new window is invisible until its first picture, for up to a second, and
  takes clicks at its place meanwhile. One that is being resized to its
  rule's `size` (the experimental flag only) is invisible for as long as
  that takes and a second more at most; a click at its place is taken or
  refused as for any window being resized, whether or not it is drawn.
- A background that fell back is shown twice, in the bar and in the status
  line. A problem in the config file is the bar's alone; one about bindings
  that could not be registered, a `--super` chord the controller rejects and
  a load it refuses outright are the status line's alone, as before. The app
  has been launched with a config that has two unknown actions and reloaded
  ([below](#what-has-been-run-for-the-closed-gaps)): stderr had the two
  warnings at every load and nothing else for them, but nobody looked at the
  panel, so that the status line no longer repeats the message, and the bar
  itself, are compiled and read only.
- With several warnings, the one the bar names is the first of them in sorted
  (byte) order, the same at every load of one file, and stderr lists them in
  that order. That choice is this port's: upstream names the parser's first
  and logs them as the parser returns them, and for unknown actions in
  `[keybindings]` the parser's order is not stable from one load of the same
  file to the next (the first of this tree's runs still printed them in the
  parser's order, and the two lines changed places between loads). For a
  table the parser reads in a fixed order the bar can so name another warning
  than upstream's does.
- A file that is refused now builds the background program again once, a
  shader compile included, because the bar's message travels with the same
  revision; upstream's failed reload redraws the bar only.
- Upstream's third error source, a keyboard layout that xkb refuses, does not
  exist: macOS owns the layouts.
- Each display bakes its own closing snapshot at upstream's density, where
  upstream shares one; upstream's refusal to fade in pixels more than a second
  old has no separate test, since what is baked is what the last frame showed.
- Blur costs memory per blurred window (a frost and a mask of the window's
  size on screen, and two padded copies while it keeps being recomputed) and
  a blur of the backdrop whenever something beneath the window changes;
  COMPOSITOR-NOTES 18.1 and 24 have the numbers.
- A screenshot holds no frost, as upstream's screenshot composer omits blur,
  and no closing snapshot, stand-in fade or error bar; a window that is
  opening is captured as the plain window. Only the first is stated by the
  port's notes; the other two were left out because a capture is of the
  canvas, and upstream's capture code was not read again for them.

### Screenshots

`Infinify msg screenshot` renders the canvas offscreen with the same compositor
and writes a PNG, upstream's `screenshot`: the active output's view by default,
`window` for one window alone on transparency with its shadow, `all` for every
window framed by `[zoom] fit_padding`, `region` for a canvas rectangle or, with
`--from-screen`, a rectangle in screen points. `--scale` is pixels per canvas
unit, whatever the zoom is. The controller resolves the region and refuses what
upstream refuses; the shell renders it at zoom 1 into a transparent target,
without output outlines and, for `window`, without the background, and reports
the size of the image it wrote. A window that is on no output is drawn from the
last picture its stream delivered, or as the placeholder fill. A `window`
capture of a live window is framed with room for its shadow, as upstream's is,
and drawn at its rule's `opacity`, else opaque, whatever `[decorations]
opacity` makes of it on screen: upstream captures an isolated window as
itself. One of a stand-in is framed at its border, as upstream frames a
stand-in, so only the shadow behind its rounded corners is in the picture.
A capture is of the canvas, as upstream's is, without the frost of a blurred
window, a window animation or the error bar
([above](#blur-window-animations-and-the-error-bar)). A window pinned to the screen is
not on it, so the view, `all` and `region` never show one, also when it covers
half the panel; `window` captures a pinned window alone, at the canvas frame
its pin shows. A widget is drawn below the other windows, and `all` frames the
canvas windows and stand-ins without counting widgets.
A `wallpaper` background is fixed to the screen, so in a capture it lies over
the canvas footprint of the output the region's centre is on, else of the
active output, cropped by the region, and the rest of the picture is
transparent, as upstream's `wallpaper_dest` places it; the bare viewport
capture is that footprint and looks as the screen does. `-o -` relays the PNG
to stdout through a temporary file, as upstream's client does; with no `-o`
the file is `infinify-screenshot-<time>.png` in the client's directory.

```sh
Infinify msg screenshot -o ~/canvas.png                 # what the active view shows
Infinify msg screenshot all --scale 0.5 -o ~/all.png    # every window, half size
Infinify msg screenshot window Safari -o ~/safari.png   # one window on transparency
Infinify msg screenshot region -1000 -500 2000 1000     # a canvas rectangle, centre and Y up
```

Differences from upstream: the file is the only thing written, so a path whose
directory does not exist is refused (`cannot write …: No such file or
directory (os error 2)`) where upstream creates the directories; one image is
rendered in one pass, up to upstream's 16384 pixels a side, where upstream
tiles; a wallpaper is cover-cropped to its output's
footprint as on screen, where upstream's capture element samples the whole
image across it (the two differ when the image's aspect is not the output's),
and with the region's centre on no output the footprint is that of the
effect's output, which for `--from-screen` is the output under the rectangle's
corner where upstream takes the active one.

### Background caches

Two of DriftWM's backgrounds are drawn from textures made in advance, in every
normal launch: one cache per output, each bounded by `[background]
cache_budget_mb` (128 by default), least recently shown chunk out first. Both
are the background module's ([BACKGROUND-NOTES.md](BACKGROUND-NOTES.md),
section 17, which lists every difference from upstream). There is no new
flag, command or control: two config keys that were accepted and ignored now
act, and a `.tif` tile path that drew the dot grid with a message now draws
the picture. [What was run](#what-was-run-for-the-background-caches) says
what was seen of them and what was not; in the app itself neither cache's
picture has been looked at.

- **`cache_shader = true`** bakes a static shader, one that declares
  `u_camera` and neither `u_time` nor `u_zoom`, into canvas-space chunks of
  1024 canvas units and pans those instead of running the shader for every
  frame. Any other shader, a textured one and any under `transparent_shader`
  renders live as before, silently. The baked picture is the live one, to
  within one level on a few pixels, at zoom 1, 0.5, 0.25 … with the camera on
  the baked level's own grid (whole canvas units at zoom 1); elsewhere it is
  that level shifted by under a pixel, or between those zooms the next
  coarser level stretched, softer, and thin features such as the dot grid's
  dots fade: that is upstream's bake. A shader that moves with the camera at
  any rate but 1:1 bakes wrong, upstream's too.
- **On a Retina display the default budget is too small for it.** A chunk is
  4.2 MB on a 1x display and 16.8 MB on a 2x one. A view that lies across the
  canvas origin on both axes, which the home view does, needs four chunks of
  the coarse cover and four of the sharp level at zoom 1: 134.6 MB against
  the 134.2 MB that `cache_budget_mb = 128` is. Such a view shows the coarse
  cover alone, one texel for every 64 canvas units, which is a blur, and
  stderr says `shader-bake: cache_budget_mb too low for this view (128 MB
  working set > 128 MB budget); showing coarse cover only. Raise
  cache_budget_mb for sharp detail.` This is upstream's arithmetic at scale
  2, not a fault of the port, and `cache_budget_mb = 256` or more is the
  setting to pair `cache_shader` with here. Nothing appears on the error bar
  or the status line for it, as upstream shows nothing. A budget below one
  cover chunk draws the shader live instead, with a line of this port's.
- **`type = "tile"` with a `.tif` / `.tiff` path** is DriftWM's gigapixel
  wallpaper: a tiled pyramidal TIFF (8-bit RGB or RGBA; `vips tiffsave in.jpg
  out.tif --tile --pyramid --bigtiff --compression=deflate`, or `tiffcp -t`
  over one file per level) of any size, centred on the canvas origin and
  repeating. Only the chunks in view are decoded, off the main thread, from
  the level the zoom calls for; until a chunk is ready its place shows the
  coarse level that is always loaded (the finest of at most 4096 pixels,
  which is not counted against the budget). The level follows the zoom alone,
  as upstream's: on a Retina display the picture at zoom 1 is the full
  resolution magnified twice, and at zoom 0.5 the half-size level where the
  full one would be 1:1. A file that is stripped, planar or not 8-bit RGB, or
  that cannot be opened, falls back to the dot grid with upstream's reason on
  stderr, the status line and the error bar. A file with one tiled level and
  no pyramid is accepted, as upstream's code accepts it. `mirror_tile` does
  not apply. A budget too small for the view keeps the coarser levels that
  fit, with one line on stderr.
- **While a cache fills** its display is redrawn by the
  [frame timer](#rendering), one frame a tick, and each frame does upstream's
  share of the work and no more: two bakes, sixteen on the frame the level
  changes, eight uploads. The shares are per frame and are not scaled to the
  rate, as upstream's are per frame of its output: on a 120 Hz display a view
  of cells never shown is sharp in half the time it takes at 60 Hz, as in
  DriftWM. The timer is started by the description whose draw left chunks
  pending and ends itself on the tick after a frame that left none; while
  nothing is pending nothing is drawn. A display that has already drawn since
  the last tick is not drawn again by it: during a flight the camera's frame
  is the tick's frame, and a chunk decoded off the main thread redraws its
  display once when it arrives. One timer follows the fastest display, so
  beside a faster display a slower one's cache is offered frames at the
  faster rate, where upstream gives each output its own.
- **A blurred window over either cache** has its frost recomputed in the
  frame a chunk is baked or arrives, as upstream refreshes it when the
  background's elements change, so the frost does not stay a blur of the
  coarse picture once the background behind it has sharpened.
- **`msg screenshot`** draws neither cache, as upstream's capture does not: a
  baked shader is rendered live, and a pyramidal TIFF from its finest level of
  at most 4096 pixels, tiled at the full picture's extent. For a picture
  larger than that the capture is softer than the display's, at the default
  `--scale 1` already: a 16384-pixel picture is captured from a level a
  quarter its size. No capture therefore shows what either cache draws.

### What is not drawn, and other limits

- Move and resize animations, and the transitions into and out of
  [fullscreen](#fullscreen): a fullscreen window is drawn alone on its
  display from the moment it is asked, and its exit is immediate. Blur, the
  open and close animations and the error bar are drawn
  ([above](#blur-window-animations-and-the-error-bar)), on a fullscreen
  display as [its section](#what-a-fullscreen-display-shows) says.
- A wallpaper is a PNG or JPEG, and so is a tile unless it is a tiled
  pyramidal TIFF ([Background caches](#background-caches)).
- A stand-in's title bar carries no text, as upstream's; its label is the
  application's name, never the window's title. Text is rasterised by CoreText
  in the configured font, or the system font when it is not installed
  (`Adwaita Sans` usually is not).
- An output draws a window only while the window's own rectangle reaches it.
  The shadow or border of a window lying just outside an output is missing
  there, where upstream would still draw it.
- A window rule asking for `decoration = "server"` gets a compositor title bar
  above the captured frame, which already has the application's own.
- The application name of a stand-in is looked up once per run: an application
  installed while Infinify runs shows its bundle identifier until a restart.
- Every managed window that was ever shown keeps one window-sized buffer, its
  last picture, until it closes or the canvas closes.
- An animated background keeps the frame timer running, at the display's
  refresh rate, while its panel is open, also when other windows cover the
  panel completely.
- A shader's compile error is several lines long. All of it goes to stderr;
  the status line is one line high, and the error bar runs the lines into one
  and cuts it at the display's width.

### What was run for rendering

On 2026-10-09 (macOS 27.2, Apple Silicon), none of it with a Screen Recording
or Accessibility grant, so **no ScreenCaptureKit buffer was ever composited**
and every window in every run was a stand-in.

**The app as built here.** `./scripts/build-app.sh` built the app from this
tree, controller and shell together, and that app was launched three times as
`--windowed 1100x700` on a private scene, config and socket, for about 3, 7
and 3 seconds, each ended with SIGTERM: exit status 0 and the socket file
removed every time. Each printed the not-managed note on stderr and adopted
nothing. The scene held three seeded placeholders: 640×420 at (200,150), 900×600 at
(1500,−300) and 560×380 at (−900,700), with the bundle identifiers of Notes,
of Safari and of an application that is not installed. Everything was driven
and read through `Infinify msg`; every PNG was opened, and the numbers below
are pixels read from the files.

- **Viewport, defaults:** 1100×636, opaque. A light dot every 80 canvas units
  on black. The first placeholder at x 200 to 839 and y 150 to 569, `#303030`,
  corners rounded, close glyph top right, the label `Notes` centred; the other
  two outside the view. The same view at `--scale 2`, over a shader
  background: 2200×1272.
- **After `msg action zoom-to-fit`** (zoom 0.2848): 3862×2233, which is
  `round(size / zoom)`, and all three stand-ins with their left edges at
  x 1381, 2681 and 281: `world − round(camera)` for each. Labels `Notes`,
  `Safari`, and the bare identifier for the application that is not installed.
- **Border and focus.** The config file rewritten while the app ran (3 px
  border, two colours) and `msg focus --id 1`: a 3 px ring of `#e5a50a` on the
  focused stand-in and of `#5a5a5a` on the other two.
- **Targets.** `window --id 1 --scale 2`: 1292×852, (640+6)×2 by (420+6)×2,
  alone on transparency. `window` with no selector and `window Safari`: 646×426
  and 906×606. `all --scale 0.5`: 1733×773, the union of the three frames plus
  80 units of `fit_padding` a side, halved. `region 520 -360 800 500`: 800×500
  with the window's corner at (80,40). `region … --from-screen` for a
  400×300-point rectangle whose corner is 100,50 inside the output: 400×300
  with the window's corner at (100,100). `window --id 1 -o -`: exit status 0
  and no file left behind, but the bytes on stdout stopped at the image's last
  newline (8044 bytes, no `IEND`), which this run did not check; see the
  2026-10-10 run below.
- **Refusals**, each an `error:` line and exit status 1 from the client: a
  path in a directory that does not exist (`cannot write …: No such file or
  directory (os error 2)`, and the directory was not created), a path in a
  read-only directory (`… Permission denied (os error 13)`), `--scale 0`
  (`scale must be a positive number`), a region of width 0, `window --id 99`
  (`no window with id 99`), `all --scale 40` (`capture 138640x61840px exceeds
  the 16384px per-side limit — lower --scale or shrink the region`).
- **Relaunch pending.** `msg relaunch --id 3` for the application that is not
  installed (the failure on stderr), then `window --id 3`: the label ends in
  ` launching…`.
- **`[background]`,** one rewrite of the config file and one capture each, no
  restart: upstream's `extras/wallpapers/static/blue_drift.glsl` (the shader
  behind the windows, the soft shadow visible on it; the same picture with
  `cache_shader = true`, which the port accepted and ignored when this was
  run, and which a capture still draws live: [Background caches](#background-caches));
  `animated/fast_smoke.glsl` (two captures a second apart differ);
  `textured/ripple.glsl` with `texture` (the image, rippled);
  a shader path that does not exist and a shader that does not compile (both
  captures byte-identical to the default dot grid, and on stderr `background
  shader '…': No such file or directory (os error 2)` and `background shader:
  compile error: …`); `type = "tile"` with a 64×64 image (repeats every 64
  units; with `mirror_tile` every 128, mirrored); `type = "wallpaper"`;
  `type = "none"` (background alpha 0, the shadow's alpha falling from 47 to 1
  over 12 pixels); an empty file (the defaults again).
- **`[decorations]`,** the same way: `border_width = 6` in two colours with
  `corner_radius = 24` and `opacity = 0.7` (6 px rings, rounder corners; the
  unfocused stand-in's pixels came out at alpha 178 in a `window` capture,
  which was a defect, since upstream never dims a stand-in: see the 2026-10-10
  run below); `bg_color`, `fg_color`, `title_bar_height = 40`, `font =
  "Menlo"`, `font_size = 18`, `font_weight = "bold"`, `shadow = false` and
  `corner_radius = 0` (body `#203040`, glyph and label `#ffcc00`, the glyph
  centred in a bar 40 high, the label in bold Menlo, square corners, no
  shadow).

**After the review fixes,** on 2026-10-10, the app was rebuilt from this tree
and launched twice more the same way, for 4 and 12 seconds, on the same seeded
scene: exit status 0 on SIGTERM and the socket file removed both times, the
not-managed note on stderr, nothing adopted. Every PNG was opened and the
numbers are pixels read from the files.

- **The earlier list, again:** the viewport at the defaults (1100×636, the
  first placeholder at x 200 to 839 and y 150 to 569, the label `Notes`);
  after `zoom-to-fit` 3862×2233 with all three stand-ins and their labels;
  a 3 px border in two colours with `corner_radius = 16`, `msg focus --id 2`
  putting the `#e5a50a` ring on that stand-in and `#5a5a5a` on the other two;
  `window --id 2 --scale 2` (1812×1212), `window --id 1` (646×426), `all
  --scale 0.25` (867×387) and `region 520 -360 800 500` (800×500); the two
  unwritable paths (`No such file or directory (os error 2)`, `Permission
  denied (os error 13)`) and `--scale 0`, each an `error:` line and status 1.
- **Stand-ins are opaque.** With `[decorations] opacity = 0.5`: the unfocused
  stand-in's body at `(48,48,48,255)` in a `window` capture, its border at
  `(90,90,90,255)`, and all three bodies `(48,48,48)` in `all`. The review
  that found the defect had read alpha 128 and `(24,24,24)` for the unfocused
  ones from the build before the fix.
- **`-o -`.** `window --id 1 -o -` redirected to a file: 9720 bytes ending in
  `IEND`, equal byte for byte (`cmp`) to `window --id 1 -o FILE` taken just
  before, and no temporary file left.
- **A shader file edited behind an unchanged config.** `[background] type =
  "shader"` naming a copy of upstream's `static/blue_drift.glsl`, with a 4 px
  border and `corner_radius = 20`: the blue shader behind a rounded,
  blue-ringed stand-in. The file replaced with `static/dark_sea.glsl` and
  `msg action reload-config`, the config untouched: the capture shows
  dark_sea. The file replaced with one that does not compile and the config
  only `touch`ed: the dot grid, and `background shader: compile error: …` on
  stderr. The file repaired and `reload-config` again: byte for byte the first
  capture. A path that does not exist: the dot grid and `background shader
  '…': No such file or directory (os error 2)`.
- **Wallpaper in captures.** A 1100×636 image of four plain quadrants (red,
  green / blue, yellow) as `type = "wallpaper"`, camera at the origin, zoom 1.
  The bare viewport capture: the quadrants meeting at (550,318) behind the
  stand-in, identical outside the label to the capture the build before the
  fix wrote. `region 110 -75 100 50`, inside the red quadrant: 5000 pixels of
  `(255,0,0,255)`, where the earlier build squeezed all four quadrants in. `all
  --scale 0.25` (865×385): the image only over x 245 to 519 and y 95 to 253,
  the view's footprint, and alpha 0 everywhere else outside the stand-ins.
  `region 1300 -318 800 636`: green and yellow for x 0 to 199, then
  transparency and the next stand-in with its shadow. A 100×50
  `--from-screen` rectangle: plain red.
- **Drawables.** With upstream's `animated/fast_smoke.glsl` at the default
  `animate_fps`, `heap` on the running app counted 1 `CAMetalDrawable` and 171
  `_NSJSONReader` objects, and the same 1 and 171 six seconds later. The
  review had counted 11 and then 84 drawables seven seconds apart in the build
  before the fix.

`msg screenshot` renders offscreen with the renderer the panels use. **What
the app's own panel showed on the display was not seen**: the session that ran
this can neither capture the screen nor drive the GUI. Nor were a live window,
a window rule, `default_mode`, `title_align` (a stand-in's bar has no text), a
second output and its outline, or `transparent_shader` in any of these runs.

**Before the two halves were built together,** the same day, outside the
repository, by the author of the shell half and not repeated on the built
app:

- `canvas-renderer.m` and the compositor, linked into a throwaway tool with a
  hand-written snapshot in the contract's shape and generated pixel buffers:
  two outputs with different cameras and zooms rendered through their layers
  and read back, and every screenshot target written to a PNG. The pictures
  were opened: windows at the expected pixels, the right way up, the focused
  border, an 0.8 opacity, a `server` title bar, a content rectangle inside a
  larger buffer, two stand-ins with application names and ` launching…`, the
  other output's outline, a window on no output in `all`. Identical snapshots
  drew nothing more, two frames for one window in one turn drew each output
  once, `animate_fps = 30` drew 14 frames in 30 ticks at 60 Hz, a missing
  shader gave the fallback note, and a reset left no layer behind.
- The same shell sources linked against a debug build of the controller as it
  then stood and launched as `--windowed 1000x700 --manual`, twice: the
  screenshot targets, two refusals and two config rewrites as above, and
  `msg action quit` exiting 0 and removing the socket.
- A compositor layer hosted like the canvas's (a sublayer of a flipped,
  layer-backed view in a borderless panel, below a button) in a throwaway
  process, read back from that process's own window: upright, under the
  button, at the output's rectangle. Twelve changed frames drawn in one turn
  of the run loop took 6 ms.

Not run by anyone: a real captured window through the compositor (colour,
alpha, the sRGB stream setting, the queue depth, the kept picture after a
stream stops, a frame redrawing only its outputs), the panels of the app
itself as seen on a display, more than one display and so the outlines in the
app, an animated background on screen and its timer's rate, the fallback note
in the status line (only its stderr copy was read), a display change while
the canvas is open, Return to desktop and reopening, the full-screen panels of
a run that is not `--windowed`, the experimental native-resize path with the
compositor, and every probe, demo and owned-fixture mode after this change
(their code path is unchanged by construction, not by a run).

### What was run for rules and rendering together

Historical evidence: invocations of `--experimental-native-resize` in this
subsection refer to the mode removed on 2026-10-12.

On 2026-10-10 (macOS 27.2, Apple Silicon), after the window rules and the
renderer became one build: `./scripts/build-app.sh`; the controller scenarios,
with one in `crates/desktop/tests/rules_flow.rs` that describes a widget, a
rule-pinned window and a canvas window for one frame; two throwaway tools; and
three launches of the built app. None had a Screen Recording or Accessibility
grant, nothing is saved as evidence, and every number below is a pixel read
from a file, or where it says so the centre of a layer.

**The drawing path, offscreen, outside the repository.** `canvas-renderer.m`,
the compositor and the background module were linked with this controller's
library into a throwaway tool. It registered one output of 1100×636 whose
top-left is the global point (300, 200), loaded a config (`[background] type =
"none"`, no border, radius or shadow, a `widget` rule with a `position`, a
`pinned_to_screen` rule with a `position`), attached three synthetic sources
whose buffers are plain red (400×300, placed at the canvas point (100, 100)),
green (the widget, 300×200, placed by its rule at (250, 200)) and blue (the
pinned window, 200×150, placed by its rule at the output-local point
(700, 343)), handed each snapshot to `-render:…` exactly as the app's view
does, and read the frame back from the output's compositor layer.

- **Zoom 0.5, camera (0, 0):** red at x 50 to 249, y 50 to 199; green only at
  x 250 to 274, where the canvas window does not cover the widget; blue at
  x 700 to 899, y 343 to 492, full size.
- **After a pan to camera (200, 80):** red at x 0 to 149, green at x 150 to
  174; blue unchanged.
- **Zoom 1, same camera:** red at x 0 to 299, y 20 to 319; green at x 300 to
  349, y 120 to 319; blue unchanged.
- **Camera (−500, −200), the canvas window under the pin:** along y 420, red
  from x 600, blue from 700 to 899, red again to 999, green from 1000 to 1049:
  the pinned window over the canvas window, the widget under it.
- **`Opacity` 0.5 written to the canvas window and to the pinned one** (the
  request `msg opacity` sends): (128, 0, 0) where the canvas window lies on
  black, (128, 128, 0) where it lies on the widget, (64, 0, 128) where the
  pinned window lies on it, (64, 64, 128) where all three overlap, and the
  widget alone still (0, 255, 0).
- **The pinned window's source removed, its slot kept:** an opaque stand-in,
  body (48, 48, 48), bar and label, at x 700 to 899, y 343 to 492, the same at
  zoom 1 and at zoom 0.5.
- **The controller's screenshot effects, performed by the same renderer:**
  the view (1100×636), `all` (560×460, the canvas window's frame and
  `fit_padding`, the widget drawn where it reaches into it) and a region, none
  with the pinned window; the pinned window alone, 200×150 at alpha 128, the
  opacity written to it; the widget alone, 300×200 and opaque.

**The resize handles under a pinned window, offscreen, outside the
repository.** A second throwaway tool compiled `main.m` itself (its `main`
renamed) with the same controller set-up, put a `DesktopView` in a window that
was never shown, set the flag `--experimental-native-resize` turns on, focused
the canvas window and called the view's `-render:`. These are the centres of the
handle layers it built, in global points, not pixels; the pinned window's
rectangle is (1000, 543) 200×150.

- **As attached, the canvas window at (400, 300) 400×300:** eight handles
  offered, eight built.
- **Its top edge's midpoint under the pinned window, the window at (900, 618)
  and cut by the output's bottom edge:** five offered, four built; the one at
  (1100, 618) is missing, and the one at (1300, 768), inside the widget's
  rectangle, is built, the widget being below.
- **Its right edge's midpoint under the pinned window, the window at
  (700, 468):** eight offered, seven built; the one at (1100, 618) is missing.
- **The same tool on `main.m` as it was before that test was added:** all five
  and all eight built.

**The app.** Two launches as `--windowed 1100x700` on a private scene, config
and socket, 3 seconds and 1 second, each ended with SIGTERM: exit status 0 and
the socket file removed both times, the not-managed note on stderr, nothing
adopted. Every PNG was opened.

- **First launch, the three seeded placeholders, an empty config.** `msg
  state` listed them with camera `550 -318`, zoom 1. The viewport capture:
  1100×636, the first placeholder's body at x 200 to 839, y 150 to 569 over
  the dot grid. After `msg action zoom-to-fit` (zoom 0.2848): 3862×2233 with
  the three bodies at x 1381 to 2020, 2681 to 3580 and 281 to 840, and the
  second `zoom-to-fit` back at `550 -318`, zoom 1. `msg focus --id 2` flew the
  camera to that placeholder's centre (`msg camera` printed `1950 -0`), `msg
  action "pan-viewport right"` on to `2050 -0`. `window
  --id 1`: 640×420; `region 520 -360 800 500`: 800×500 with the body's corner
  at (80, 40); `window --id 1 -o -` redirected to a file: equal byte for byte
  (`cmp`) to the file capture, ending in `IEND`, and no `infinify-screenshot-*`
  file left in the temporary directory. The
  config rewritten to name a shader file that does not exist, then `msg action
  reload-config`: the dot grid in the next capture and `background shader
  '…/missing.glsl': No such file or directory (os error 2)` on stderr. `msg
  pin --id 1`: `stand-ins can't be pinned`; `msg opacity --id 1`: `no window
  with id 1`.
- **Second launch, one placeholder pinned in the scene file.** The scene came
  from a throwaway program driving this controller in process: it moved
  "Terminal" to the canvas point under the output-local point (500, 200),
  pinned it with a `Pin` write and saved; there, with its synthetic source,
  the placement read `pinned` true, `opacity` and `decoration.opacity` both
  0.5 after an `Opacity` write of 0.5. In the app `msg state` listed the two
  others under `windows` and `windowed #3 org.example.seed [230, -72] 560x380
  "Terminal"` under `pinned`, the same after `pan-viewport right` and at zoom
  0.5, while `msg move --id 3` read `780 -390`, then `880 -390`, then
  `830 -272`. Three viewport captures, at launch, after the pan and at zoom
  0.5 (2200×1272): the first placeholder's body at x 200, then x 100, then
  x 650 to 1289 and y 468 to 887, and **no pinned placeholder in any of
  them**, where the panel draws it from (500, 200) to (1059, 579) over the
  first one: pixels (900, 400) and (1000, 500) of the first capture are the
  black of the background. `window --id 3`: the pinned placeholder alone,
  560×380. `all`: 2360×1030, the two canvas placeholders with 80 units
  around them, no third. `msg pin --id 3` with and without `on` or `off`:
  `stand-ins can't be pinned`; `msg opacity --id 3` with and without a value:
  `no window with id 3`; `msg move --id 3 10 10` and `msg resize --id 3 800
  600`: upstream's two refusals. The scene file saved at exit held the pin at
  `[500, 200]`.

After the handle test was added the app was rebuilt and launched once more on
the pinned scene (2 seconds, SIGTERM, exit status 0, socket removed): the same
`msg state`, a viewport capture of 1100×636 with the first placeholder's body
at x 200 to 839, y 150 to 569 and black at (900, 400) and (1000, 500),
`pan-viewport right` (`msg move --id 3` from `780 -390` to `880 -390`),
`zoom-to-fit` (zoom 0.4273, the two canvas placeholders), `zoom-reset`, `msg
focus --id 2` (camera `1950 -0`), `window --id 3` 560×380, `all` 2360×1030,
and the same refusals of `pin` and `opacity`.

Not run: the app's own panel as seen on a display, so the widget and pinned
layers, the pinned space and an opacity as the app presents them were drawn
only by the offscreen tool; a rule resolved in the app, a widget there, a
window with a real source in any layer; a pinned window under a `server` rule
and its dot; a second display; the resize handles left off a widget or a
pinned window as the app presents them, a handle under a pinned window being
checked only as the layers above; a handle under a window stacked above the
focused one that is not pinned; any pointer press.

### What was run with every other milestone built in

Rules and rendering were built on a tree that had the config file and managed
windows and nothing later. Joined to window navigation and native focus, hot
corners, the event stream and autostart, camera motion and trackpad gestures
(`c11fece`, `5812d6f`, `1f44d0f`, `f083155`), the points where the two sides
meet are these: one most-recently-focused order, which a widget and a pinned
window never enter however their focus is settled; the navigation actions,
clicks, followed native focus, trackpad moves and `send-to-output` treating
both as [above](#window-rules-widgets-and-pinned-windows); one frame timer
for camera motion and animated backgrounds; one `render` path that adopts the
config's drawing settings, draws through the compositor, reports the pointer
for cursor edge pan and publishes the State; a screenshot answered on its own
connection beside subscribers; and `outputs_settled` sent from `openPanels`,
which every way of opening the canvas goes through.

On 2026-10-10 (macOS 27.2, Apple Silicon) that build passed
`./scripts/build-app.sh`, the controller scenarios of every module
(`rules_flow` with four scenarios added for the joined paths, `render_flow`,
`gesture_flow`, `motion_flow`, `lifecycle_flow`, `platform_actions_flow`,
`navigation_actions_flow`, `config_flow`, `ipc_flow`, `view_actions_flow`,
`controller_flow`, `navigation_flow`, `focus_cycle_flow`) and the headless
coordinator regression, and was launched three times as `--windowed 1100x700`
on a private scene, config and socket, for 6, 16 and 8 seconds, driven through
`Infinify msg`. No launch had Screen Recording access (each printed the
not-managed line), so every window was one of three seeded placeholders, and
nothing from them is saved as evidence. Observed, each read back over the
socket or in a PNG `msg screenshot` wrote:

- **Empty config.** `state`: the three placeholders at `[520, -360]`,
  `[1950, 0]` and `[-620, -890]`, `layout British (en)`, `pinned 0`, one
  output `windowed` of 1100x636 at camera `550 -318`. The viewport capture
  held the first placeholder's stand-in at x 200 to 839, y 150 to 569 on the
  dot grid. `action center-nearest right`: `focus` answered `#2` and `camera`
  `1950 -0`, and the capture there held its 900x600 stand-in from (100, 18);
  `pan-viewport right`: `2050 -0`; `zoom-to-fit`: camera `750 -390`, zoom
  0.28484848484848485, a 3862x2233 capture with the three stand-ins at their
  seeded places, and a second one back at `2050 -0`, zoom 1. `screenshot
  window --id 1` wrote 640x420, `region 520 -360 800 500` 800x500, and `-o -`
  piped to a file gave the same bytes as the file capture, ending in `IEND`,
  with no temporary file left. `cycle-windows forward` answered `ok` and
  changed nothing (placeholders are never in the order it walks);
  `center-nearest left` focused `#1` at `520 -360`. `toggle-pin-to-screen`
  answered `ok` and left the focused placeholder alone; `move-to-bookmark 1`
  moved it to `[-1750, 1750]`; `pin --id 1`: `stand-ins can't be pinned`;
  `opacity --id 1`: `no window with id 1`; `layout`: `British`; `set-trackpad
  toggle` twice: `ok`. A `[background]` shader path that names no file, then
  `reload-config`: `background shader '…/missing.glsl': No such file or
  directory (os error 2)` on stderr and the dot grid in the capture.
- **A scene with one placeholder pinned** (made by a throwaway program driving
  this controller in process, at the output-local point (500, 200)), a 3 px
  border in two colours and `camera_speed = 0.05`. `state` listed `windowed #3
  org.example.seed [230, -72] 560x380 "Terminal"` under `pinned` and the other
  two under `windows`, the same after `pan-viewport right` and at zoom 0.5,
  while `msg move --id 3` read `780 -390`, `880 -390` and `830 -272`. The three
  viewport captures held the first placeholder alone, in the unfocused border
  colour, and nothing at the pin's rectangle; `screenshot window --id 3` held
  the pinned one alone, 566x386 with its border. `pin --id 1` and `pin on
  --id 3`: `stand-ins can't be pinned`; `opacity`: `no window with id N`;
  `move --id 3 10 10` and `resize --id 3 800 600`: upstream's two refusals.
  With a `--json subscribe` client connected, `center-nearest right` flew for
  about two seconds: three viewport screenshots were answered on other
  connections during the flight, the subscriber holding 12, 24 and 35 lines
  after each and 148 once it landed at `1950 -0` with `#2` focused, where the
  capture showed its stand-in from (100, 18) in the focused border colour.
  Every one of the 463 lines of that stream listed window 3 alone under
  `pinned`, and no two consecutive lines were equal. `toggle-pin-to-screen`,
  `move-to-bookmark 1`, `cycle-windows forward` and `center-nearest left`
  answered `ok`; `focus --id 3` focused the pinned placeholder without a
  flight, and `center-nearest left` then `center-window` from there left `#2`
  focused with the camera on its centre, the pinned one still under `pinned`.
  The scene saved at exit held the pin at `[500, 200]`.
- **An animated shader background** (upstream's `fast_smoke.glsl`). Two
  viewport captures half a second apart differed. With only the background
  animating, a subscriber received no line beyond its first in one second.
  `center-nearest right`, `pan-viewport right`, `zoom-to-fit` and back and
  `home-toggle` and back each landed exactly (`1950 -0`, `2050 -0`, `750 -390`
  at 0.28484848484848485, `0 -0`), the subscriber held 123 lines after the
  last flight and 123 a second later, and with the background back to the
  default a `pan-viewport left` landed at `1950 -0`.
- Every launch exited 0 on SIGTERM and removed its socket; each subscriber
  exited 0.

Not run in that build, beyond everything the sections above list as never run:
the app's own panel on a display, so neither the compositor layer in it nor
the frame timer's redraws of an animated background were seen (the captures
are offscreen renders, and the stream's silence at rest shows only that the
timer publishes nothing by itself); a hot corner, a trackpad gesture, a key or
a pointer press, so `watchCorners` on the joined timer, a move swipe over a
widget or a pinned window and a click on either are compiled and read only; a
live window of any kind, so native focus on a widget or a pinned window, a
rule, a widget, and `send-to-output` of a pin (there was one display); a
screen change or Return to desktop and Open canvas, so `outputs_settled` was
sent only by the launch's `openPanels`; cursor edge pan under the joined
`render`.

### What was run for effects

On 2026-10-10 (macOS 27.2, Apple Silicon), on a tree that had every milestone
above and nothing later (neither the pointer policy nor window sizing, which
[the next section](#what-was-run-for-effects-with-the-pointer-policy-and-window-sizing-built-in)
adds), after the controller's half and the shell's half of
[the effects](#blur-window-animations-and-the-error-bar) were written
separately from one contract and then built together. Nothing had a Screen
Recording or Accessibility grant, so **no ScreenCaptureKit buffer was blurred,
opened or closed**: every picture below is a plain-coloured synthetic buffer or
a stand-in. Nothing is saved as evidence.

**Build and controller.** `./scripts/build-app.sh` built the app, controller
and shell together, without a change to either side. `cargo fmt --check` and
`cargo clippy --all-targets -D warnings` on `driftwm-desktop` were clean, and
the controller scenarios passed: `effects_flow` (4, the milestone's own),
`render_flow` (7), `rules_flow` (21), `lifecycle_flow` (25), `config_flow`
(12), `ipc_flow` (8), `controller_flow` (4), `navigation_flow` (5). The
headless coordinator regression was not run: none of its sources changed.

**The renderer alone, offscreen, outside the repository.** A throwaway tool by
the author of the shell's half linked `canvas-renderer.m`, the compositor and
the background module and fed them hand-written snapshots in the contract's
shape, two outputs at backing scale 2 (zoom 1 and zoom 0.5), reading each
frame back from the output's layer. It was built again from the final sources
and run once more when the halves were joined, with the same log but for
timing: events already listed at a renderer's first frame, after `reset` and
in a second renderer are not replayed; the blur flag reaches a window and not
a stand-in, changes 34287 pixels inside the translucent window's rectangle and
none outside, and leaves a capture byte for byte the same; an opening window
is invisible until its first picture, or for 1.06 s without one, and the timer
loop stops by itself; a closing snapshot is baked after the source dropped its
buffer, 856x656 texels for a 400x300 window at density 2, and for a 300x200
one 328x228 where only the zoom 0.5 output shows it and 656x456 where it is
pinned; two closes and
two dismissals are listed newer fade, older fade, newer snapshot, older
snapshot, with the window that closed first on top; `animation_speed = 1`
plays nothing; a window with no placement plays nothing; a capture taken
while a snapshot plays does not hold it.

**Controller and renderer together, offscreen, outside the repository.** A
second throwaway tool linked the same three files with this controller's
library and drove the controller through the exported C ABI as the app does:
`set_platform`, `load_config` on real files, `load` of a scene of three
placeholders, one output of 1100x636 at backing scale 2, `outputs_settled`,
`adoption_complete`; each snapshot went to `-render:…` and `-flush` exactly as
the app's view sends it, with a 60 Hz loop standing in for the frame timer
while `-animates:draw:` said yes. The bar in each of its five states, the
frame without it, the frosted window, and the first frame of the close, of the
close into a stand-in, of the adoption and of the dismissal were opened as
PNGs; everything else below is a pixel or the renderer's state as the tool
printed it.

- **Launch, a config holding one comment.** `render.effects`
  `{blur_radius 2, blur_strength 1.1, animate_blur_fps 20, animation_speed
  0.5, animation_scale 0.95}`, `render.errors` `[]`, revision 0, no event, no
  bar; the first stand-in `decoration.blur` false.
- **An unknown action in `[keybindings]`.** `load_config` warned `config:
  invalid action 'no-such-action': unknown action: no-such-action`;
  `render.errors` held that line, revision 1, and the frame had the line in
  white on the black strip at the bottom. With two such keys and
  `animation_speed = 7`: three warnings, `render.errors` the first followed by
  ` (+2 more)`, `animation_speed` 1. Which of the two unknown actions came
  first differed between two runs of the tool.
- **`[effects` without its bracket.** `load_config` failed with `config
  error: TOML parse error at line 1, column 9` and five more lines; the bar
  read ``config error: TOML parse error at line 1, column 9 | 1 | [effects | ^
  invalid table header expected `.`, `]` `` on one line, the tables stayed as
  they were, the revision went from 2 to 3, and the same file again left it
  at 3.
- **A warning and a `[background]` shader file that does not exist.** The
  bar: the config line, a bullet, `background shader '…/missing.glsl': No such
  file or directory (os error 2)`, cut with an ellipsis at the output's width.
  With the shader alone: `render.errors` `[]` and the background's line alone
  in the bar.
- **The file fixed, `[effects]` changed, `[decorations] blur = true`, opacity
  0.6.** `render.errors` `[]`, the bar gone; `render.effects` and the frame's
  effects `{4, 2.0, 144 (500 was written), 0.1, 0.8}`; the stand-in's
  `decoration.blur` still false.
- **A window attached without a place** (the request an automatic adoption
  sends), 400x300, its buffer plain red, withheld at first. The controller
  placed it at (350, 168) over the first stand-in and logged `open`, serial 1;
  its `decoration.blur` was true and its opacity 0.6. The element was opening
  and unstarted, nothing was drawn at its centre, and nothing animated. With
  the buffer delivered `-contentChanged:` answered YES, the loop ran 0.71 s
  (upstream's length at speed 0.1 is 0.73 s) and stopped, the centre went from
  the stand-in's grey to (152, 44, 44), red at 0.6 over it, and the frost had
  been computed about 30 times: in the PNG the stand-in's label behind the
  window is a soft glow.
- **`window_closed` for it**, the tool dropping the buffer before drawing as
  the shell does. `standin` false, event `close`; one snapshot of 428x328 in
  the closing bucket, (218, 40, 40) in its first frame, nearly the opaque red,
  and fading to the grey beneath over 0.71 s, then no element left; the
  buffer's retain count was back to the tool's own 1.
- **`suspend_on_close = true`, a second window, green, closed.** `standin`
  true, event `close_to_standin`; an alpha-only snapshot over the stand-in,
  gone after 0.68 s with the stand-in's label where the green was. IPC
  `Relaunch` on it: `Ok`, one `launch` effect, `launching` true. A window of
  the same application attached: it took slot 5, event `standin_adopted`; the
  stand-in stayed whole (an alpha-only fade, unstarted, nothing animating)
  until the window's blue buffer arrived, then faded over it in 0.68 s.
- **IPC `Close` on the first stand-in.** `Ok`, event `standin_dismiss`, no
  placement left; the stand-in, a little smaller in the first frame, faded
  over 0.68 s to the blue window it had been beneath. The same on the third
  stand-in, which the output does not show: the event, no element, nothing
  animating.
- A scene saved at the end mentions none of `effects`, `lifecycle_events`,
  `errors` or `blur`. After `-reset` the layer, its renderer and every buffer
  were released. The same run under the address and undefined-behaviour
  sanitizers reported nothing, and `leaks --atExit` reported 0 leaks (it also
  said the unsigned tool was not debuggable).

**The app.** One launch as `--windowed 1100x700` on a private scene, config
and socket, about 3 seconds, ended with SIGTERM: exit status 0, the socket
file removed, the not-managed note on stderr. `msg state` listed the three
placeholders at camera `550 -318`. The config was rewritten three times, each
followed by `msg action reload-config`: an unknown action (stderr: `config:
invalid action 'no-such-action': unknown action: no-such-action`), the broken
`[effects` header (stderr: `config error: TOML parse error at line 1, column
9` and its five lines), then a valid file with a changed `[effects]` and
`[decorations] blur = true` (nothing on stderr). Each message was printed
twice, presumably once for the file watcher's reload and once for the
action's. A viewport
capture after each of the three was byte for byte the capture taken before
the first (`cmp`): no bar in a capture, and no frost. `msg focus --id 1` then
`msg action close-window` dismissed the placeholder in view, and `msg close
--id 3` one out of view: `msg state` listed two windows, then one, and every
later request was answered. The scene file saved at exit holds one window and
none of the words `effects`, `lifecycle_events`, `errors` or `blur`.

Not run, and not known from any of the above: the app's own panel on a
display, so the bar, a frost, a fade and an opening window were never seen
where the owner will see them, and the dismissal in the app is known only to
have left it answering; `render.effects`, `render.errors` and
`lifecycle_events` as the app's own controller reports them, since `msg`
reaches none of the three (the tool above read them from the same library); a
captured window of any kind, so a real window's first picture, its last
buffer at the moment it closes, capture on demand stopping a stream before a
close, and whether a native window's own translucency lets a frost through;
the frame timer itself against a display's refresh (the tools
looped by hand, and a tick there took about 25 ms with the read-back; the
timer has since become a display link, whose callback rate was measured by
itself, see [Camera motion](#camera-motion)); an
animation during a camera flight; a pinned window or a widget opening or
closing through the controller; a second display; a native-resize source
closing; a config error at launch; blur over an animated background.

### What was run for effects with the pointer policy and window sizing built in

Historical evidence: invocations of `--experimental-native-resize` in this
subsection refer to the mode removed on 2026-10-12.

The effects were built on a tree that had rules and rendering and nothing
later. Joined to the [pointer policy](#pointer-motion-sloppy-focus-and-pick-mode)
and to [window sizing](#window-sizing-actions), the points where the sides
meet are these:

- **One frame timer.** A window that opens or leaves keeps it running as an
  animated background does: it is started without the flag that says it
  serves camera motion, so each of its frames takes the pointer's part (the
  waiting hover, cursor edge pan's report), ticks no camera and leaves the
  hot corners to the idle poll, and it stops with the last animation. That is
  the code as read; no run observed the timer.
- **An opening window that is owed a size.** The effects' renderer opened a
  window on its first picture, or after a second without one. A window whose
  rule names a `size` is being resized as it appears, and no picture of it is
  drawn until that has settled, which can take longer than a second. The
  renderer now reads the size transaction from the snapshot
  (`native_resize`, while one of its effects is outstanding) and holds the
  opening, and a stand-in fade waiting with it, until the last effect is
  answered, then gives the first settled picture its second; a picture that
  arrives before that, of the size the window is leaving, starts nothing. Ten
  seconds is the most a window is held, so a resize that is never answered
  cannot keep one invisible. Without `--experimental-native-resize` there is
  no size transaction and nothing changes.
- **A close while a size is owed** is refused by the controller, as before,
  and logs nothing; the shell reports the close again when the resize has
  been answered, and that close is the one logged.
- **⌃⌥-click.** The controller's `forget` now logs the same event as a
  dismissal for a placeholder, so the click fades it; the shell's code for
  the click is unchanged.
- A reload that fails still answers with `focus_follows_mouse` beside its
  message, and a capture still holds no bar, frost or fading element.

On 2026-10-10 (macOS 27.2, Apple Silicon), nothing with a Screen Recording
grant and nothing saved as evidence:

**Build and controller.** `./scripts/build-app.sh`, `cargo fmt --check` and
`cargo clippy --all-targets -D warnings` on `driftwm-desktop` were clean, and
the controller scenarios passed: `effects_flow` (5: the `forget` cases, the
whole reply of a refused reload and one scenario for a size that is owed were
added), `render_flow` (7), `rules_flow` (22), `sizes_flow` (30),
`pointer_flow` (16), `lifecycle_flow` (25), `config_flow` (12), `ipc_flow`
(8), `controller_flow` (4), `navigation_flow` (5), `gesture_flow` (21),
`motion_flow` (9), `native_resize_flow` (25), `navigation_actions_flow` (12),
and `tests/e2e/desktop-navigation.sh`.

**The renderer alone, offscreen, outside the repository.** A throwaway tool
linked `canvas-renderer.m`, the compositor and the background module as
merged, described one output with one window from hand-written snapshots and
asked `-animates:draw:` after each step whether an open animation had begun.
With a size owed: not when the window mapped, not on a picture delivered
during the baseline read (`-contentChanged:` answered NO), not when the
output was described again with that picture, not 1.3 seconds on with the
picture withheld, not when the transaction had just ended without a settled
picture; then on the first settled picture (`-contentChanged:` YES), and in a
second pass at the description that came with one. With no size transaction:
on the first picture, or after 1.1 seconds without one, as before the merge.
After a transaction that ended and left no picture: not at once, and yes a
second later. With an effect never answered: not at 9.5 seconds, not at 10.2,
yes at 11.3. Built against the effects' own renderer, before the merge, the
same tool reported the open begun on the baseline-read picture and, in the
second pass, after a second on nothing: seven of its checks failed there. The
tool drew no frame and read no pixel. It shows when the frame description
says an animation is running, which is what starts the frame timer.

**The app.** One launch as `--windowed 1100x700` on a private scene, config
and socket, 6 seconds, ended with SIGTERM: exit status 0, the socket file
removed, the not-managed note on stderr. Every window was one of three seeded
placeholders. `msg state` listed them at camera `550 -318`; `action
center-nearest right` landed at `1950 -0` with `#2` focused, `pan-viewport
right` at `2050 -0`, `zoom-to-fit` at `750 -390`, zoom 0.28484848484848485,
and again back at `2050 -0`, zoom 1; `zoom-to-fit-snapped` at `1950 -0`, zoom
0.7933333333333333, and back. `fit-window`, `fit-window-snapped`,
`fill-window`, `grow-window right` and `shrink-window right` each answered
`action not implemented on macOS yet: <name>`, and `msg resize --id 2 800
600` `resize is not implemented on macOS yet: native layout resize is not
available`. The config was then rewritten twice, each followed by `msg action
reload-config`: an unknown action under `[keybindings]` (stderr: `config:
invalid action 'no-such-action': unknown action: no-such-action`, twice, and
`msg state` still answered), then `[effects] blur_radius = 4`,
`animation_speed = 0.25` and `[decorations] blur = true` (nothing more on
stderr). The three viewport captures taken before the error, with it and
with blur on were the same bytes; the picture, 1100x636 and looked at, is the
focused stand-in on the dot grid with no bar along the bottom and no frost.
`msg focus --id 2` then `msg action close-window` dismissed that stand-in:
`msg state` listed two windows and `msg focus` none; a capture taken at once
and one a second later were the same bytes, the dot grid alone. The scene
saved at exit holds two windows and none of the words `effects`,
`lifecycle_events`, `errors` or `blur`.

Not run: the app's panel was not looked at, so the dismissal's fade, like
every other effect, is known only to have left the app answering, and `msg`
cannot show it. No pointer event was sent, so the ⌃⌥-click and the fade it
now plays, a hover on a frame that only an animation keeps alive, and the
timer stopping after one are compiled and read only. No live window existed,
so nothing opened or closed in the app, no rule was resolved and no size
transaction ran there: the held opening is known from the tool's hand-written
snapshots and from the controller scenario that pins down what those
snapshots hold, never from a window being resized. The app was not launched
with `--experimental-native-resize` for this join.

### What was run for the background caches

On 2026-10-10 (macOS 27.2, Apple Silicon, a 2x display), with no Screen
Recording or Accessibility grant, so every window was a placeholder and
nothing was read from the screen. Nothing was saved as evidence; the tools
and pictures were throwaway files outside the repository.

**What cannot be seen from here.** `msg screenshot` draws neither cache
([above](#background-caches)), and no agent session can capture the panel. So
in the app the caches are known by two things only: that it kept answering
and exited cleanly with them on, and the lines the caches print on stderr
when a view exceeds the budget. Their pictures were compared outside the app,
by a tool that links the same `background.m`, `background-tiff.m`,
`compositor.m` and `canvas-renderer.m`.

**The app as built here.** `./scripts/build-app.sh` built it from this tree
(the first build with the controller's `cache_budget_mb` key and the shell's
caches together; it compiled and linked as written). It was launched five
times as `--windowed 1100x700` on a private scene of three placeholders,
config and socket, for 8, 13, 7, 9 and 7 seconds, each ended with SIGTERM:
exit status 0 and the socket file removed every time. The view was 1100×636
points. A background was changed by rewriting the config file, which the
app's own watcher loaded. Every PNG was opened. The first launch's script
sent a zoom right after each pan, which cancels the pan, so its six pairs
were all at one camera; the second moved.

- **`cache_shader` on and off, upstream's `static/dark_sea.glsl`.** Viewport
  captures at cameras `550 -318`, `5000 2000` and `-250000 180000`, each at
  zoom 1 (1100×636) and 0.5 (2200×1272), once with `cache_shader = true` and
  once with `false`: the six pairs are byte-identical files, and so were
  three more under `cache_budget_mb` 1, 40 and 512. That is what a capture
  that renders the shader live must give; it says the capture is unaffected
  and nothing about the bake.
- **The bake's own lines.** With the default budget and the view across the
  origin at zoom 0.5: `shader-bake: cache_budget_mb too low for this view
  (128 MB working set > 128 MB budget); showing coarse cover only. Raise
  cache_budget_mb for sharp detail.` At the other five views under the
  default budget, and at 512: no line. With `cache_budget_mb = 40` at
  `-250000 180000`, zoom 0.5: the same line with `(80 MB working set > 40 MB
  budget)`. With `cache_budget_mb = 1`: `shader-bake: cache_budget_mb too low
  for this view's coarse cover (16 MB > 1 MB budget); rendering the shader
  live. Raise cache_budget_mb to bake it.` The numbers are the 2x chunk sizes
  and the budgets the configs named: the value crossed from the controller's
  snapshot into the panel's own cache.
- **A 4096×2048 three-level pyramid** (Deflate, 256-pixel tiles, `tiffcp`)
  against the same picture as a PNG tile: viewport captures at zoom 1, 0.5
  and 0.25 (1100×636, 2200×1272, 4400×2544) byte-identical files. A picture
  this size is its own fallback level, so this is the capture's level drawn
  where a plain tile is.
- **A 16384×8192 seven-level pyramid** against the same picture as a
  16384×8192 PNG tile, the same three views: 38.8 %, 50.4 % and 53.9 % of
  pixels differ, by up to 196 levels. Looked at, they are the same scene in
  the same place, the TIFF's softer: the capture is the 4096-pixel level
  stretched four times, as upstream's is. `--scale 0.25 region 8192 8000 8800
  5088`, across the picture's wrap seam, against that level as a PNG tile at
  `--scale 1 region 2048 2000 2200 1272`: byte-identical files, 2200×1272.
- **Files upstream refuses,** each one rewrite of the config: a stripped
  TIFF, `tile bg '…/stripped.tif': TIFF is stripped, not tiled — needs a
  tiled, pyramidal TIFF`; an 8-bit greyscale tiled one, `… unsupported color
  type Gray(8) (need RGB8 or RGBA8)`; a path that does not exist, `… open
  …/not-there.tif: No such file or directory (os error 2)`. The captures
  under the first two are byte-identical to the capture under `type =
  "default"`. A 2048×1024 TIFF with one tiled level and no pyramid: no
  message, and the picture in the capture.
- **The TIFF cache's own lines,** at zoom 1 with the 16384×8192 pyramid:
  `chunked tile-bg: cache_budget_mb too low for this view (8 MB budget);
  keeping the coarser levels that fit. Raise cache_budget_mb for sharp
  detail.` and the same with `(2 MB budget)`; none under the default.
- **Twelve reloads of a TIFF background in a row** (the budget alternating
  between 8 and the default): `footprint` gave 350 to 353 MB for the process
  after every second one and 266 MB a second after the last. Nothing grew
  with the reloads. No more was measured of memory in the app.

**The caches' pictures, outside the app.** The tool was rebuilt from this
tree and run again. Frames were compared as raw BGRA.

- **Baked against live,** upstream's `dot_grid.glsl` and its four `static/`
  shaders at ten cameras, zooms and scales each, 800×600 points. Ten pairs
  byte-identical: the dot grid in all six cases at zoom 1, 0.5 or 0.25 with
  the camera on the level's grid, at 1x and 2x, and all five shaders at
  camera (250000, −180000). The other on-grid pairs differ by one level on 1
  to 1078 pixels (at most 0.056 %). Off the grid they differ as upstream's
  bake does: at camera (300.4, −150.3), 0.1 % to 66 % of pixels by up to 173
  levels; at an odd camera at zoom 0.5, 0.4 % to 85 % by up to 250; at zoom
  0.7 and 0.33, 0.5 % to 77 % by up to 251.
- **The shell's renderer on a detached 2x layer of the panel's size,** dark
  sea. Baked equal to live, byte for byte, at camera (5000, 3000) at zoom 1
  and at zoom 0.5 (budget 512 for the second). With the origin at the centre
  of the view at zoom 1: under the default budget 86.4 % of pixels differ
  from the live frame by up to 129 levels, the coarse cover; under 256, 506
  pixels by one level; under 1, identical, the live fallback. Each drew once
  and not again in thirty further timer ticks.
- **The 16384×8192 pyramid against its PNG tile.** On a 1x target at zoom 1,
  cameras (0, 0), (−8300, −4200) across the wrap seam and (8000, 3900):
  byte-identical. At 2x: 7187 of 3.84 million pixels, on chunk edges, where
  upstream's chunks clamp. At zoom 0.5 on 1x: one level on 92 % (the
  generator's rounding against the GPU's). On the renderer's 2x layer: 0.2 %
  at zoom 1 and 51 % at zoom 0.5, where the level follows the zoom; with
  `cache_budget_mb` 8, 5.6 %, and with 2, 82 %, the fallback level alone.
  Three draws (the fallback, then the chunks as they arrived), then none.
- **The budget over a pan,** 1728×1117 points at 2x. Baked shader, 400
  frames: 112.4 MB at most under 128 (44 chunks baked, 37 evicted, 21 frames
  on the coarse cover; an earlier text of this line said 26, which the pan
  did not reproduce when it was run again after the review: with
  `pink_cloud.glsl` and with `dark_sea.glsl` it gave 21, and the other
  figures as written) and 497.9 MB under 512, never above the budget after a
  frame. TIFF, 300 frames: 128.0, 32.0 and 8.0 MB at most under those
  budgets, never above, and no chunk at all under 3 and 0.

**Not run or not seen:** either cache's picture on the app's panel, and so a
chunk arriving on screen and the frame timer that serves a filling cache;
eviction in the app; a real gigapixel file, a file written by `vips` or GDAL,
BigTIFF or any compression but Deflate in the app or in this run of the tool
(section 17 of the notes records the module reading BigTIFF, LZW, PackBits,
uncompressed and RGB JPEG when it was written; that was not repeated); a
damaged tile, which the notes say is not detected; a window with a picture
over a cached background, and a frosted one anywhere but in the tool (below);
a second display, a 1x display in the app, a display whose scale changes;
memory over a long run.

**After the review, the same day.** Two fixes changed what is drawn or kept:
a blurred window's frost is recomputed in the frame a chunk lands
(`compositor.m` asks the background for its chunk generation before it
prepares the frosts), and a block decoded after a fullscreen window concealed
its output is discarded when it arrives. The tool was rebuilt from the tree.

- **Frost over a cached background,** one translucent blurred window through
  the compositor's offscreen encode: a view, then frames with only the time
  advancing until nothing was pending, against a renderer with no frost yet
  drawing the settled view. Baked dark sea after a jump of the view at 1x
  and at 2x, and on the frame after five concealed ones; the baked dot grid
  the same way at 2x; the 16384×8192 pyramid after a jump at 1x, 2x and zoom
  0.5, and from its first frame. In all eight the frost was recomputed on
  the one or two frames a chunk landed in and on none after, no pixel
  differed inside the window or outside, and the PNG files were
  byte-identical. With `cache_shader` off and with the PNG tile: no
  recompute after the first frame, no pixel. Looked at: the first frame of
  a jump (frost over the coarse cover's blocks), the settled one (a fine
  blur of the sharp field) and a settled pyramid.
- **Late blocks under a fullscreen window,** the shell's renderer on a
  detached layer: a pyramid described once, concealed before its decodes
  were received, then a second of the timer. Twelve runs each way. Before
  the fix, the three runs that had two blocks still decoding at the
  concealment held both a second later; after it, eleven runs had one or
  two and none was held.
- **Unchanged by the fixes:** the renderer on the detached 2x layer gave the
  nine comparisons above to the pixel, and the TIFF pans 128.0, 32.0 and 8.0
  MB at most under those budgets (82, 95 and 26 uploads; 50, 87 and 24
  evictions) and no chunk under 2.
- **The app, built again, three launches** of 13, 8 and 8 seconds on the
  same private scene, config and socket, each ended with SIGTERM: exit
  status 0 and the socket file removed. Dark sea with `cache_shader` on and
  off at the three cameras and two zooms: six pairs of byte-identical files,
  and three more under `cache_budget_mb` 1, 40 and 512, with the same three
  bake lines on stderr. The 4096×2048 pyramid against its PNG at zoom 1, 0.5
  and 0.25: byte-identical files. The 16384×8192 pyramid against its PNG:
  38.8 %, 50.4 % and 53.9 % of pixels, by up to 196 levels, and against its
  4096 level as a PNG tile at the matching scale: byte-identical. The
  stripped, the greyscale and the missing file: upstream's three texts, and
  captures byte-identical to the dot grid's (the missing one captured this
  time). The single-level TIFF: no message, its picture. The TIFF cache's
  lines for budgets 8 and 2. Every distinct PNG was opened. None of this
  shows either fix: a capture draws no cache, the scene has no blurred
  window and no fullscreen one.

**At the merge with the display-link frame timer and the tap bindings, the
same day.** Everything above ran on the tree the caches were built in, whose
frame timer was a 60 Hz `NSTimer`. The tree that landed has the
[display link](#rendering) and the [tap tracker](#tap-bindings) beside the
caches; `./scripts/build-app.sh` compiles `background-tiff.m`,
`frame-driver.m` and `tap-keys.m` once each and built it as written.

- **A filling cache under the display link, outside the app.** A second
  throwaway program linked the landed `frame-driver.m`, `canvas-renderer.m`,
  `compositor.m`, `background.m` and `background-tiff.m` with the release
  controller library and drove a layer in no window by `main.m`'s rule for
  the frame timer, copied: it is not the shell running. On a 120 Hz display,
  baked dark sea on 3000×2000 points at 1x: a jump to cells never shown baked
  2 in the description's draw and left 7; the timer started, ticked 120 times
  a second, baked 2 a tick and ended by itself; half a second idle and one
  more description gave no tick and no chunk. A flight of 40 camera frames,
  each described inside its tick as the shell does: up to 4 chunks a tick at
  79 ticks a second as the two sides merged, because the tick drew the
  camera's frame and then forced a second one; 2 a tick at 119 to 120 ticks
  a second once a display that has drawn since the last tick is no longer
  forced ([Background caches](#background-caches)). At 2x on 1728×1117
  points: 4 a tick at 94 a second before, 2 at 111 after. The 8192×4096
  pyramid below: its timer started with 9 or 12 decodes outstanding and
  ended by itself two or three ticks later, and the ready handler was never
  called off the main thread. The tables are in
  [BACKGROUND-NOTES.md](BACKGROUND-NOTES.md), 17.9.
- **The app, four launches** as `--windowed 1100x700` on a private scene of
  three placeholders, config and socket, for 2.9, 5.5, 7.4 and 5.9 seconds,
  each ended with SIGTERM: exit status 0 and the socket file removed. The
  first two were of the build before the change to the forced frame, the
  last two of the build after it. Every PNG named was opened.
  - **Dark sea, `cache_shader = true`, default budget.** `msg state` listed
    the placeholders at camera `550 -318`; `action center-nearest right`
    settled at `1950 -0` with `#2` focused, `pan-viewport right` at `2050
    -0`, `zoom-to-fit` at `750 -390`, zoom 0.28484848484848485, and again
    back at `2050 -0`, zoom 1. A viewport capture showed the Browser
    placeholder over the shader, which a capture renders live. stderr had
    the bake's line `(128 MB working set > 128 MB budget)` twice, for the
    launch view and for the zoom-to-fit one, both across the origin.
  - **Started with `cache_budget_mb = 1`:** it answered, with `shader-bake:
    cache_budget_mb too low for this view's coarse cover (16 MB > 1 MB
    budget); rendering the shader live.` on stderr, and its capture was the
    same file as one with `cache_shader = false`. Then, each by a rewrite of
    the config and `reload-config`: a shader path that does not exist,
    `background shader '…/not-there.glsl': No such file or directory (os
    error 2)` and a capture byte-identical to `type = "default"`'s; an
    8192×4096 four-level pyramid (`tiffcp -t -w 256 -l 256 -c zip` over one
    generated file per level), no message and its picture in the capture;
    the same under `cache_budget_mb = 2`, the TIFF cache's line, twice, 146
    ms apart; a stripped TIFF, upstream's text and the dot grid's capture;
    and `center-nearest right` at `1950 -0` with `#2` focused.
  - **`cache_budget_mb = 256`, twice, after the change.** Nothing from the
    caches on stderr. `msg camera 40000 30000` and `-60000 20000`, cells
    never shown, arrived; the capture there and one of the pyramid, loaded by
    a rewrite, were as expected. In the second of the two `center-nearest
    right`, `pan-viewport right` and `zoom-to-fit` gave the numbers above.
    In the first, `center-nearest right` focused `#2` and the camera came to
    rest at `1661.93 3682.86`, not `1950 -0`, after 14 reads of it where 5
    are usual; `pan-viewport right` then moved it by exactly 100 and
    `zoom-to-fit` went to `750 -390` and back to it. The same binary, config
    and script gave `1950 -0` in the next launch. A scroll reaching the
    panel, which is on the owner's display, would leave that trace; nothing
    recorded says what it was.
- **Still not seen:** either cache's picture on the app's panel; the shell's
  own frame block serving a filling cache, a flight over one in the app, or
  a window's picture arriving while one fills; eviction in the app; a second
  display, and so the slower display beside a faster one; a tap, since a
  windowed launch installs no monitor.

## Configuration

A normal run is configured exactly like DriftWM: one TOML file in upstream's
grammar decides key bindings, mouse bindings and settings. The parser, defaults
and binding tables are upstream's own code (`driftwm-core`); the controller maps
them to a Mac keyboard and the shell registers what it reports.
[CONFIG.md](../../crates/desktop/CONFIG.md) is the controller's contract and has
the complete default table.

With no explicit background `type`, `path` or `texture`, each display inherits
its macOS wallpaper still, scaling, clipping and fill color. File metadata, image
decoding and upload happen away from the main thread. Output rendering, exports
and completed image loads reuse the cached observation; only host refreshes or
changed configuration/display resolution query the Mac again. Those AppKit
queries remain on the main thread, as required by the
[desktop-image API](https://developer.apple.com/documentation/appkit/nsworkspace/desktopimageurl(for:)).
Set the following in the config to enable or disable pan/zoom parallax (default
`true`):

```toml
[background]
parallax = false
```

Explicit wallpapers also support this switch. Grid, tile and shader behavior
is unchanged. macOS video/dynamic assets without a loadable single still use
the canvas background fallback. Source changes refresh on display/Space/session
events and a low-frequency check while navigation is idle. The app reads these
settings; it never changes the Mac wallpaper.

If macOS still names a deleted source file, the shell can reuse that source's
path-hashed image-provider cache entry for the current display resolution. This
is a read-only fallback for the observed macOS 26 cache format; unknown cache
layouts are ignored. Decoding retains the Mac's scaling and fill settings. An
unavailable inherited image keeps the last loaded wallpaper or the canvas grid,
logs the failure, and retries while idle without leaving an error bar onscreen.

- **File.** `--config /absolute/path.toml`, else
  `$XDG_CONFIG_HOME/infinify/config.toml`, else `~/.config/infinify/config.toml`
  (upstream's own path logic with `infinify` as the directory name; its
  `DRIFTWM_CONFIG` variable still overrides the default path). A missing file is
  not an error while the run has read no file: DriftWM's built-in defaults
  apply. The app never writes the file.
- **Problems.** A file that cannot be read or parsed leaves the previous
  configuration in force (at launch: the defaults). So does a file that goes
  missing after the run has read it, which is upstream's read failure
  (`config: failed to read <path>: No such file or directory`): settings,
  bindings and bookmarks stay as they were. While the file has such an
  error, or a value upstream's parser warns about, upstream's
  [error bar](#blur-window-animations-and-the-error-bar) shows the message
  along the bottom of every display
  until a later load is clean, and nothing else on screen repeats it. Notes
  about bindings that were skipped are
  shown once in the status line, until the next status message. Every message
  also goes to stderr, upstream's own verbatim, a load's warnings in sorted
  order.
- **Live reload.** The app watches the file and its directory and reloads
  within about 150 ms of a change, whether the file is written in place,
  replaced by a rename, created or deleted. The `reload-config` action does the
  same on demand. Every load re-registers the hot keys and refreshes the status
  line, the tooltips and the Quit button. Deleting or moving the file away
  keeps the configuration and reports the read failure until the file is back;
  upstream's watcher says nothing about a deleted file and reports it only on
  `reload-config`.
- **Modes.** `--source`, `--demo`, `--demo-probe`, `--demo-probe-guard` and the
  owned-resize modes read no config, reject `--config` and `--super`, and keep
  the fixed controls they were validated with (in `--demo`: Option-drag pan,
  Command-wheel zoom, Control-Option-drag move, and the Control-Option view and
  bookmark chords).

### Modifiers and `--super`

| DriftWM | macOS |
| --- | --- |
| `ctrl` | Control ⌃ |
| `alt` | Option ⌥ |
| `shift` | Shift ⇧ |
| `super`, and `mod` while `mod_key = "super"` (the default) | the super chord: Command ⌘ unless `--super` says otherwise |
| `mod3` | none; such a binding is skipped with a warning |

`--super CHORD` picks the super chord at launch: a `+`-joined subset of `ctrl`,
`alt` and `cmd`. `--super cmd` gives upstream-literal chords (`mod+a` is ⌘A,
`mod+ctrl+Right` is ⌃⌘→), which takes ⌘A, ⌘W, ⌘Z, ⌘0 to ⌘4 and others away from
every application while the canvas is open. A chord the controller rejects is
reported in the status line and the default stays.

A binding that holds super together with a modifier the super chord already
contains would be indistinguishable from the binding without it, so that
modifier is displaced: `ctrl` becomes Command and `alt` becomes Command-Shift.
With `--super ctrl+alt`, `mod+ctrl+Right` is ⌃⌥⌘→ and `mod+alt+Right` is ⌃⌥⇧⌘→.
When the super chord itself contains Command there is nowhere to displace to and
the binding is skipped with a warning. Two bindings that land on one physical
chord are settled by upstream combo text: the first in sorted order keeps the
chord and the other is reported.

A binding on a character is registered on the key that types that character in
the current keyboard layout (unshifted, or with Shift for a binding that holds
Shift), and resolved again when the input source changes: `mod+z` is the key
labelled Z on QWERTZ and on AZERTY alike. Upstream matches the active layout's
keysym first in the same way. When no key types the character,
`[input.keyboard] layout_independent = true` (upstream's default) falls back to
the key's US ANSI position, where upstream falls back to another configured
layout's Latin keysym; with `false` the binding is left out and the status line
says so. A key the layout resolves takes its chord before one that fell back.
Media keys
(volume, brightness, play) are not Carbon hot keys and are not registered, so
the Mac's own handling of them is untouched.

### Default key bindings as registered

With no config file and the default super chord. Hot keys are global and exist
only while a canvas panel is open; `--windowed` registers none. While the
focused window's rule passes a binding (`pass_keys`), its chord is not
registered either, ⌃⌥Esc and `quit` excepted
([Passing keys and presses](#passing-keys-and-presses-to-an-application)).

| Chord | DriftWM binding | Action |
| --- | --- | --- |
| ⌘Tab / F3 | `mod+Tab` / `F3` (Mac defaults) | `zoom-to-fit` toggle |
| ⌘A | `mod+a` | `home-toggle` |
| ⌘W | `mod+w` | `zoom-to-fit` |
| ⇧⌘W | `mod+shift+w` | `zoom-to-fit-snapped` |
| ⌘= / ⌘- | `mod+equal` / `mod+minus` | `zoom-in` / `zoom-out` (repeat) |
| ⌘0, ⌘Z | `mod+0`, `mod+z` | `zoom-reset` |
| ⌃⌘ arrows | `mod+ctrl+<arrow>` | `pan-viewport <direction>` (repeat) |
| ⇧⌘ arrows | `mod+shift+<arrow>` | `nudge-window <direction>` (repeat) |
| ⌥⌘ arrows | `mod+alt+<arrow>` | `send-to-output <direction>` |
| ⌘ arrows | `mod+<arrow>` | `center-nearest <direction>` |
| ⌘C | `mod+c` | `center-window` |
| ⌘X | `mod+x` | `focus-center` |
| ⌥Tab / ⌥⇧Tab | `alt+Tab` / `alt+shift+Tab` | `cycle-windows forward` / `backward` (repeat) |
| ⌘1 to ⌘4 | `mod+1` to `mod+4` | `go-to-bookmark 1` to `4` |
| ⇧⌘1 to ⇧⌘4 | `mod+shift+1` to `mod+shift+4` | `set-bookmark 1` to `4` |
| ⌘Return | `mod+return` | `exec-terminal`: `$TERMINAL`, else `open -a Terminal "$HOME"` |
| ⌘D | `mod+d` | `exec-launcher`: `$LAUNCHER`, else `open -a Apps` |
| ⌘L | `mod+l` | `exec /usr/bin/pmset displaysleepnow`, standing in for upstream's `spawn swaylock -f -c 000000 -kl` (see [Linux-only default commands](#linux-only-default-commands)) |
| ⌘Q | `mod+q` | `close-window`: close the focused window, or dismiss a focused placeholder |
| ⌘E | `mod+e` | `toggle-cursor-pan` |
| ⌘T | `mod+t` | `toggle-pin-to-screen`: pin the focused window to the screen, or return it to the canvas |
| ⌃⇧⌘Q | `mod+ctrl+shift+q` | `quit` |
| ⌃⌥Esc | none (the shell's own) | exit, until a binding takes the chord |

Those are 42 of upstream's 57 default key bindings. ⌥Tab and ⌥⇧Tab are taken
from every application while a canvas panel is open; rebind or unbind
`cycle-windows` in the config file to give them back. ⇧⌘W is newly taken the
same way: `zoom-to-fit-snapped` used not to run, so its chord used to stay with
the applications. The rest are not registered, so their chords stay with the
applications:

- Until 2026-10-11, 3 whose action did not run in a default launch: ⌘F
  (`toggle-fullscreen`), and ⌘M and ⇧⌘M (`fit-window`,
  `fit-window-snapped`). All three run in every normal run now, so ⌘F, ⌘M
  and ⇧⌘M are registered as well (45 of 57, which the bindings trace of
  `tests/e2e/scoped-sizing.sh` lists as the 45 key bindings that run), and so
  is any key a config binds to `fill-window`, `grow-window` or
  `shrink-window`; see [Window sizing actions](#window-sizing-actions) and
  [Fullscreen](#fullscreen). No test has pressed one: a windowed run
  registers no hot key.
- 8 on media keys (volume, mute, brightness, play, next, previous), which macOS
  handles itself, and 4 on keys a Mac keyboard lacks (`Print`, `shift+Print`,
  `XF86AudioPause`, `XF86AudioStop`).

The two Mac overview defaults bring the total to 47 registered bindings. Explicit config bindings, unbindings and `disable_defaults = ["keys"]` take precedence. Command-Tab and F3 use a session event filter while desktop mode is active; the known Mission Control keycode 160 aliases F3. Other hardware packet formats remain unverified. No system shortcut preferences are changed.

**Key repeat.** A held hot key whose action upstream marks repeatable
(`zoom-in`, `zoom-out`, `pan-viewport`, `nudge-window`, `cycle-windows` and
`spawn`, `grow-window` and `shrink-window` among those that run) fires again after `[input.keyboard] repeat_delay` (200 ms) and then
`repeat_rate` (25) times a second. It stops when the key is released, when
another hot key is pressed, when the chord's modifiers are let go, and on Return
to desktop or quit. A held `spawn` binding therefore starts its command again
on every repeat, as upstream's does, with one exception: a `spawn` whose program
is not found when the config is loaded does not repeat at all, and a command
that `sh` reports it could not find or run (exit status 127 or 126) ends the
repeat in progress and says `sh could not run: <command>` on the status line.

### Tap bindings

A `[keybindings]` entry that is a bare modifier chord is DriftWM's tap binding:
`"alt+shift" = "switch-layout next"` runs when the chord is pressed and let go
with nothing else on top. DriftWM's defaults bind none. The chord maps to the
Mac keyboard as a key binding's does (the table above); the controller lists
the chords, and the shell watches the modifiers and tells it when one completes
([contract](../../crates/desktop/CONFIG.md#tap-bindings)).

- **The rule is upstream's** (`TapTracker`). The chord is every modifier held
  since the first went down. A key, a mouse button going down or up, a scroll,
  or a trackpad gesture that begins while it is held makes it an ordinary
  binding prefix, and nothing fires. Otherwise the action runs at the first
  release, once: holding Option and tapping Shift again does nothing until
  every modifier has been let go. Pointer motion does not count. A hot key
  under the same modifiers is unaffected: `alt+shift+k` runs its own action,
  and the tap does not follow it.
- **Modifiers** are Control, Option, Shift and Command. Caps Lock is an
  ordinary key, as upstream's lock keys are, and cancels a tap. Fn is ignored.
- **Nothing is intercepted.** The modifiers still reach the application, and a
  window rule's `pass_keys` withholds no tap, as upstream's does not. The
  action is given the pointer and whether a modifier is still down, as a hot
  key's is: after `alt+shift` one of the two is still held, so a tap bound to
  `cycle-windows` keeps its cycle open until that one is let go.
- **How the shell knows.** Modifier changes are observed system-wide
  (`flagsChanged`, through one NSEvent global and one local monitor). No key
  press is listened for: whether a key or a button landed on top is read from
  the login session's event counters when the chord begins and again at its
  release, which needs no permission and observes no event. A volume,
  brightness or media key is no key event on a Mac; it arrives as a
  system-defined event, as a copy of every mouse button change does, and that
  kind is counted with the keys and the buttons. The shell hears of a modifier
  after it went down, later still when its main thread is busy, so the session
  is also asked how long ago it last saw each counted kind: one seen since the
  timestamp of the change that begins the chord cancels it, though the first
  reading of the counters already holds it. A scroll and a trackpad gesture
  are the canvas's own events. The momentum macOS adds after a scroll does not
  count: libinput has none.
- **Accessibility.** Apple documents that a global monitor is sent key-related
  events only while the app is trusted for Accessibility, and names no
  exception for modifier changes. Whether an untrusted Infinify is sent them
  has not been observed. If it is not, a tap fires only while Infinify itself
  is the active application, and nothing says so; hot keys are unaffected.
  When Accessibility is granted while the app runs, the monitors are installed
  again when the shell next reads that access, which it does with every read
  of native focus, at least once a second
  ([Native focus is followed](#native-focus-is-followed)). Not tried.
- **When.** Taps are watched exactly while the config's hot keys are
  registered: from the moment the canvas opens (at launch, or when the
  permission window hands over: nothing is watched while that window is up)
  until quit, again after every config load and every rebuild of the panels,
  and never in a windowed run or a fixture mode.
  A chord already held when watching starts never fires. The tracker holds no
  timer and nothing ticks it: neither the frame timer nor the check for lost
  input ([Camera motion](#camera-motion)) calls it.
- **Differences from DriftWM.** Two keys of one modifier (both Shifts) count as
  one, so such a chord fires when the last of them is let go, not the first. A
  key that was already down when the chord began cancels it only by being let
  go while the chord is held; held throughout, it is not seen and the tap
  fires, where DriftWM's first tap over a held key does not. The release is
  heard of late too, and a key or a button that lands after it, before the
  shell is told, cancels a tap DriftWM would have fired. Whatever else macOS
  sends as a system-defined event cancels a tap as a media key does: Sticky
  Keys and Slow Keys announce a key with one (`IOLLEvent.h`), so with either
  on no tap is expected to fire, which was not observed. A scroll or a gesture
  that is not over the canvas (over the menu bar or the Dock) is not seen.
  Upstream forgets a chord when its session locks; here a chord whose events
  were missed (secure input, the lock screen) is dropped when the next change
  both adds and removes a modifier, or by the counters if anything was typed
  or clicked meanwhile, and otherwise is not noticed.

### Linux-only default commands

Upstream's default bindings run `swaylock`, `wpctl`, `brightnessctl`,
`playerctl` and `grim`, which a Mac does not have. A **default** binding whose
program is not found on `PATH` (the config's `[env] PATH` when it sets one, else
the app's own) is not registered as upstream wrote it:

| Upstream default | On a Mac without that program |
| --- | --- |
| `mod+l` = `spawn swaylock -f -c 000000 -kl` | ⌃⌥L runs `exec /usr/bin/pmset displaysleepnow`: the displays go dark, and macOS asks for the password as System Settings › Lock Screen says. It does not repeat while held. |
| volume up, down and mute = `spawn wpctl …` | nothing registered: macOS handles the volume keys itself |
| brightness up and down = `spawn brightnessctl …` | nothing registered: macOS handles the brightness keys itself |
| play, next and previous = `spawn playerctl …` | nothing registered: macOS handles the media keys itself |
| `Print`, `shift+Print` = `spawn grim …` | no such key on a Mac keyboard; screenshots stay the system's ⇧⌘3, ⇧⌘4 and ⇧⌘5 |

Two default chords therefore behave differently from earlier builds, with no
config file at all. ⌃⌥L used to start `swaylock`, which `sh` could not find, so
nothing visible happened; it now puts the displays to sleep. And ⌃⌥⇧⌘ with an
arrow key (`send-to-output`) used to be left with the applications because the
action did not run; it is now a global hot key while a canvas panel is open.
`"mod+l" = "none"` and `"mod+alt+Left" = "none"` (and the other three arrows)
give them back.

A binding **you** write in `[keybindings]` is always registered exactly as
written, a missing program included (that one only loses its key repeat, and
stderr and the status line say so once after the load). Where one of those five
programs is installed, its default binding is upstream's own again. macOS has no
public command that locks the session whatever the Lock Screen setting says, so
"lock" here is as strong as that setting; to bind something else, write
`"mod+l" = "exec <your command>"`, or `"mod+l" = "none"` to free the chord.

### Displays, hot corners, layouts and autostart

**Display names.** An `[[outputs]]` entry is matched by `name`: a display's UUID
(`Infinify msg state` prints it as the output's name), `windowed` for the
`--windowed` panel, or `"*"` for every display without an entry of its own. An
exact entry replaces the `*` entry whole, as upstream: one without a
`hot_corners` table has no hot corners.

**Hot corners.**

```toml
[[outputs]]
name = "*"
[outputs.hot_corners]
top_left = "zoom-to-fit"
bottom_right = "exec-launcher"
# threshold = 4                  # zone size in points, upstream's default
# disable_while_dragging = true  # upstream's default
```

The action runs once when the pointer arrives within `threshold` points of both
edges of that corner, and again only after the pointer has left the corner and
come back. With `disable_while_dragging` nothing runs while a mouse button is
held or a canvas gesture is in progress, and a drag that ends inside the corner
does not fire it either: the pointer has to leave and return. The rule is
upstream's `check_hot_corners`, with these differences:

- A display's corners are the corners of its panel, which is the whole
  display and is also its output, so a pointer flicked into a physical
  screen corner counts, the top two under the menu bar. A hot corner macOS
  itself has set fires there as well. With `--windowed` they are the corners of that window,
  and count only while it is the window under the pointer: covered there by
  another window, or left on another Space, it has no pointer in its corner, as
  upstream's nested window is sent no motion then.
- The pointer is looked at only while some corner is bound, every 80 ms and 60
  times a second during a camera flight, not on every motion as upstream. A
  pointer that passes through a corner and out again between two looks is
  missed; one that comes to rest there is not.
- Corners are watched only while a canvas panel is open, and never in the
  fixture modes. macOS's own Hot Corners (System Settings › Desktop & Dock) are
  not touched and fire as well if you have set any.
- `disable_when_fullscreen` (upstream's default, true) keeps a display's
  corners from firing while a window is [fullscreen](#fullscreen) on that
  display; set it to `false` for corners that fire all the same. The entry is
  still recorded, so after the window leaves fullscreen the pointer has to
  leave the corner and come back. Fullscreen runs in every normal run
  ([Fullscreen](#fullscreen)).

A corner's action runs as the same action on a key would at that moment, with
the pointer where it is and the modifiers that are down: `focus-center` takes
the window under the pointer, and a `cycle-windows` step fired with a modifier
held stays open until the cycle's hold modifiers are let go (see
[Cycling and hold-to-commit](#cycling-and-hold-to-commit)). Any other action
ends a cycle in progress first.

**Sending to another display.** `send-to-output <direction>` and
`send-cursor-to-output <direction>` pick the display as upstream picks an
output: from the centre of the current display, the nearest other display whose
centre lies within about 60 degrees of the direction. The current display is,
for the window, the first whose view shows the window's centre, and when none
shows it the display under the pointer; for the pointer, the display under the
pointer (the first display when it is over no panel). The window is moved in the
world so that it
appears on the target display where window navigation would park it there
(`focus_placement`), at that display's current zoom; its size and the cameras do
not change, and the native window is not touched. The pointer is moved with
`CGWarpMouseCursorPosition` to the centre of the target display's view. With one
display both do nothing, as upstream.

**Keyboard layouts.** DriftWM's layouts are xkb groups from its config. Here
they are the keyboard input sources enabled in System Settings › Keyboard ›
Input Sources, in the order of the input menu. `switch-layout next` and `prev`
step through them and wrap, and `switch-layout <index>` selects by 0-based
position (an index past the end selects nothing and the status line says so).
Infinify only selects among sources you have already enabled: it never enables,
disables, installs or reorders one. The selected source, whoever selected it, is
what `Infinify msg layout` and the `layout` of `msg state` report: its localized
name, and with `--short` its first language code (`en` for the British layout;
upstream reports the xkb layout token, so two layouts of one language differ
there and not here). `[input.keyboard] layout`, `variant`, `options`, `model`,
`remember_layout_per_window`, `num_lock` and `caps_lock` are read and unused:
macOS owns all of them.

**Autostart.** `autostart = ["cmd", …]` at the top of the config file runs each
command once, 100 ms after the app has started and its socket answers, exactly
as an `exec` binding would (`/bin/sh -c`, the `[env]` environment, and
`INFINIFY_SOCKET` naming this instance's socket, so `Infinify msg …` in a
command talks to the app that started it). A launch that shows the permission
window instead of its canvas holds them until the canvas opens: the window's
Relaunch starts the run again, and they would otherwise start twice. A launch
whose saved scene could not be loaded starts none. It never
runs again: not on a reload, not when the list changes, not after a display
change. A restart by launchd after a crash is a new launch and runs them
again. If the file cannot be read or parsed at launch nothing starts, then or
later. `--windowed` and `--manual` run them at launch, as upstream's nested
backend does; the fixture modes read no config and start nothing.

### The usable area

DriftWM places and measures against an output's usable area: the output less
its panels and bars. On a Mac those would be the menu bar and the Dock, which
macOS draws above the canvas panels.

**The shell sends no usable area.** By the owner's decision of 2026-10-10 the
canvas covers each display edge to edge and reserves nothing for the menu bar
or the Dock: windows may sit beneath them, and both stay visible on top
([Desktop mode](#what-a-normal-run-is) has the panel that does it). Every
output is registered by its screen bounds alone and is usable whole, in a
normal run, a windowed one and the fixture modes alike. This is a deliberate
difference from DriftWM, not something that waits to be built.

- **What follows.** Everything DriftWM measures in the usable area measures
  the whole output here: a new window's place, `focus_placement`, centring,
  Fit, fit and fill, Home and a bookmark's point, the pointer's target on
  another display
  ([the controller's list](../../crates/desktop/NAVIGATION.md#the-usable-area)).
  With a Dock that stays on screen, a new or a centred window is centred on
  the display and not on what the Dock leaves of it, Fit pads from the
  display's edge and not from the Dock's, and a window that reaches that edge
  continues beneath the Dock. A normal run's output is its display whole, so
  the menu bar lies over the top of the output as the Dock lies over an edge
  of it: a window placed or centred high comes to rest partly beneath the menu
  bar. (When this section was written an output began 64 points below the top
  of its display, under the toolbar strip of that build, and a menu bar no
  taller than the strip covered none of it. The strip went the same day.)
- **Drawing.** The coverage rule of [Rendering](#rendering) tests a window's
  frame against the whole output.
- **The controller can hold one.** `register_output` takes an optional
  `usable_rect_local` and `set_usable_area` replaces it, and the controller
  measures the rectangle wherever upstream measures an output less its
  panels, with scenarios of its own. The shell sends neither, so that side is
  inert. A shell file that read `NSScreen.visibleFrame` and sent both was
  written with those commands and removed before it landed, on that decision;
  it never ran in the app
  ([what was run](#what-has-been-run-for-tap-bindings)).

### Default mouse bindings as dispatched

Every left, right, middle and other button press and every scroll first asks
the controller for the binding of the physical modifiers held, in the `window`
context when the pointer is over a window (placeholders included) and the
`canvas` context otherwise. Upstream's precedence applies: the pointer's own
context before `anywhere`.

| Press or scroll | On a window | On empty canvas |
| --- | --- | --- |
| left click or drag | focuses the window, then the application's | pan (`left`); released within 5 points, unfocus |
| two-finger scroll | the application's | pan (`trackpad-scroll`) |
| mouse wheel | the application's | zoom (`wheel-scroll`) |
| ⌥ left drag | move the logical window (`alt+left`) | nothing |
| ⌥⇧ left drag | move its cluster (`alt+shift+left`) | nothing |
| ⌥ / ⌥⇧ right drag | `resize-window` / `resize-window-snapped`: raises and focuses the window and resizes it from the edge or corner nearest the press, with its snap cluster for ⇧ ([Resizing a window with the pointer](#resizing-a-window-with-the-pointer)) | nothing |
| left drag just outside a window's frame | resizes the window by that edge (`resize_on_border`) | the same: the band is around the window |
| ⌥ / ⌥⇧ middle | `fit-window` / `fit-window-snapped` ([Window sizing actions](#window-sizing-actions)) | nothing |
| ⌃⌥ middle | `toggle-fullscreen` ([Fullscreen](#fullscreen)) | nothing |
| ⌃⌥ left drag | pan (`mod+left`) | pan |
| ⌃⌥ two-finger scroll / wheel | pan / zoom (`mod+trackpad-scroll`, `mod+wheel-scroll`) | pan / zoom |
| ⌃⌥⌘ left drag | `center-nearest` by pointer swipe (`mod+ctrl+left`): one step to the nearest window the way the drag pulls the canvas, taken 16 points from the press | the same |
| anything else | the application's; a press focuses the window first | nothing |

A move or resize binding pressed on a widget starts no gesture, and the status
line says why for two seconds; the widget then gets the press as a plain
click, as upstream's does. On a screen-pinned window the move binding drags
the window in screen space, and a resize binding raises and focuses it, starts
no gesture, says why, and is not passed to the application
([Window rules](#window-rules-widgets-and-pinned-windows)).
Over a live window the lookup also names that window: a binding its
`pass_mouse` rule claims is not run, and the press or scroll goes to the
application as an unbound one
([Passing keys and presses](#passing-keys-and-presses-to-an-application)).
A resize binding picks its edges from the pointer's place in the window, a 3×3 grid whose centre resizes from the
bottom right, as upstream's resize grab does. A mouse binding that names an
action first focuses the window under the pointer, a placeholder included, then
runs the action. A press bound to move or resize a window raises and focuses
it before the drag begins, as upstream's does, a screen-pinned window
included, and the native focus follows as after a click. A resize press does
so also where a resize is turned away (a detached placeholder or an
application that takes no size). A move the controller
refuses focuses nothing, where upstream has no such refusal. A move by
[trackpad gesture](#trackpad-gestures) focuses and raises its window too, as
upstream's. After a
two-finger scroll has panned, scrolls stay with the canvas for 150 ms even if a
window slides under the pointer, as upstream. One gesture runs at a time: a
second button pressed during a gesture is ignored. Upstream's `wheel-up` and
`wheel-down` triggers are a lookup of their own, made first for every event of
a mouse wheel and never for a two-finger scroll: a notch bound to an action
runs it once per wheel line, ten at most for one event, and the event goes no
further; a notch with no such binding, or one the window under the pointer
claims by `pass_mouse`, is then looked up as the scroll it also is, as
upstream does. No default binding is on a notch, and none has been turned on
a real wheel. The grammar has no
name for the back and forward buttons. Pinch is not a mouse binding: it is a gesture,
below. A pan or zoom from this table is timed, scaled and limited by the
controller, see [Camera motion](#camera-motion).

### Trackpad gestures

Normal runs only; the fixture modes take no touches and keep their fixed pinch
zoom. DriftWM is handed swipe, pinch and hold gestures by libinput and binds
them in the `[gestures]` tables. macOS has no such stream, so the shell makes
one and the controller dispatches it exactly as upstream dispatches libinput's:
[GESTURES.md](../../crates/desktop/GESTURES.md) has the three commands
(`gesture_begin`, `gesture_update`, `gesture_end`), the dispatch and the default
table as it runs on a Mac. What a gesture then moves is
[Camera motion](#camera-motion)'s, the same as for the pointer: a swipe that
pans is the timed pan of a two-finger scroll and drifts on the same momentum, a
pinch that zooms is scaled, limited and snapped by the controller, and a swipe
that moves a window is the drag of a bound button press, edge pan included.

| Fingers | Where the stream comes from |
| --- | --- |
| 3 or more | raw trackpad touches, recognised by `trackpad-gestures.m` |
| 2, pinching | AppKit's magnify events, sent as a `pinch` of 2 fingers: its scale is the running product of each event's `1 + magnification`, with no rotation and no delta |
| 2, scrolling | not a gesture: the `trackpad-scroll` mouse binding above |

Every canvas view accepts indirect touches and hands each event's touches to one
recogniser, `DWTrackpadGestures`, a state machine with no AppKit in it, fed
`(identity, x, y, phase, time)` in millimetres and emitting the begin, update
and end events. Its rules and every constant are written out at the top of
`trackpad-gestures.m` beside the libinput behaviour each imitates. In short:

- The finger count is fixed once a gesture has begun. Before that each landing
  or lift restarts recognition, and motion is not read for 50 ms after it. After
  it, a different count must last 100 ms, then the gesture ends cancelled and
  recognition starts over; all fingers lifting ends it at once, not cancelled.
- Fingers that move the same way are a swipe: `dx`, `dy` are the mean movement
  of all fingers, 10.5 units for each millimetre of travel, a constant standing
  in for libinput's accelerated pointer units. Upstream's `swipe_threshold` of
  12 is therefore a little over a millimetre.
- Fingers that close, open or turn against each other are a pinch: `scale` is
  the distance between the farthest and the nearest touch over what it was when
  the pinch was recognised, `rotation` the change of their angle in degrees.
- Fingers that have not moved more than 1 mm for 180 ms are a hold. Moving ends
  it cancelled; lifting ends it, which is when a hold binding fires.
- Three fingers that land and lift within 180 ms a step, without moving, are a
  tap. A swipe beginning within 300 ms of it carries `doubletap`, which is how
  upstream's `3-finger-doubletap-swipe` (move a window) is reached.
- A touch the system cancels, or one a frame no longer reports, ends the gesture
  cancelled.

Two misreads of these rules are known from scripted touch sequences and are
left in:

- Fingers closing on a thumb that stays still are not a pinch. Nothing is
  recognised while they move, and when they stop the touches become a hold. The
  same touches are two fingers scrolling above a resting thumb, which a pinch
  would zoom, so only the other half is a pinch: a thumb closing on fingers that
  stay still. Otherwise both must move.
- Three fingers side by side that slide more than a millimetre as they land and
  then lie still become a swipe at the next touch event after 150 ms, with
  almost no motion in it, and never the hold they were resting into.

`gesture_begin` carries the modifiers held, the output under the pointer and
whether a window or empty canvas is under it (a placeholder is a window), as a
press does. Each update and the end say whether a modifier is physically down
at that moment, which is what a hot key's action is told: a `cycle-windows` the
gesture fires then keeps its cycle open until the hold modifiers are let go
([Cycling and hold-to-commit](#cycling-and-hold-to-commit)), and any other
action it fires ends one. A gesture begins only with the pointer over an
output and no button drag in progress; its begin withdraws a native focus
request still in flight and leaves a settled open cycle alone. A press on the
pad first ends an open cycle as every canvas press does, then ends the gesture
cancelled before it stops
camera motion, so a pan the press interrupts does not coast. While a swipe or
pinch of three or more fingers is running, scroll and magnify events are
dropped, in case macOS derives them from the same fingers. For the same case,
its begin ends a scroll those fingers had started: the drift that scroll was
about to launch is not launched, at its 50 ms delay or at its lift, so the
swipe's own end is the only launch. A magnify event is
sent to the controller once, as a gesture event and never as a `zoom_by` too.
The reply is an action's: a flight, a coasting camera or the edge pan under a
moved window keeps the frame timer running
(`needs_frames`), `dirty` saves the scene, a focus request (a move's, or that
of a window navigation action the gesture fired) goes to the navigation
coordinator like the request of any other reply
([What focusing does natively](#what-focusing-does-natively)), and the status
line shows what a
threshold gesture fired (`Home`, `Zoom to fit`), the refusal of an action that
does not run here yet, and the note of a resize that is refused (a
screen-pinned window's).

**macOS takes three- and four-finger touches for itself first.** Infinify
changes no system setting. For the canvas to receive those finger counts
cleanly, turn these off yourself in System Settings (the names recent macOS
releases use; they were not checked against this release's panes):

- Trackpad > More Gestures: Mission Control, App Exposé, Swipe between
  full-screen applications, Launchpad, Show Desktop, and Swipe between pages if
  it is set to three fingers.
- Trackpad > Point & Click: Look up & data detectors, if it is set to "Tap with
  Three Fingers" (it would take the tap of a doubletap-swipe).
- Accessibility > Pointer Control > Trackpad Options: three-finger drag, which
  turns three fingers into a mouse drag.

Left on, a system gesture and the canvas both see the fingers until macOS takes
the touches, at which point they arrive cancelled and the gesture in progress
ends cancelled: a pan keeps what it moved and stops there, and a hold fires
nothing. Upstream's cancelled swipe coasts, because libinput cancels a swipe
when one finger lifts ahead of the others. Here such a swipe ends uncancelled
when the other fingers follow within 100 ms, and cancelled only after those
100 ms, too late to launch anything. So a pan that ends cancelled while still
moving has lost its touches, and the shell follows the end of every cancelled
pan with `cancel_navigation` on that display.

Not done: an unbound gesture is not forwarded to the application under it
(upstream forwards it to the client), so with the default table a bare
two-finger pinch over a window now does nothing where it used to zoom the
canvas. `resize-window` by gesture begins the same resize grab a bound
press begins ([Resizing a window with the pointer](#resizing-a-window-with-the-pointer));
it has been run in controller scenarios only, never with fingers.

What changes for someone who used the previous build:

- Three fingers now pan and pinch, four fingers pinch to `zoom-to-fit` and
  `home-toggle`, and a three-finger tap followed by a three-finger swipe moves
  the window under the pointer, panning the canvas under it at the display's
  edge. After a three-finger pan the camera drifts as after a two-finger
  scroll (`[navigation] drift`, 0 turns it off), with one difference: three
  fingers that stop and stay down hold the view still, where two start the
  drift under them after 50 ms.
- A two-finger pinch over a window does nothing unless Control-Option is held.
  On empty canvas it still zooms, now scaled by `[zoom] trackpad_speed`,
  stopping at the zoom-out limit of the view actions (half the zoom that fits
  all windows) instead of 0.001, and settling on 1:1 when it ends within 0.05
  of it.
- A four-finger swipe, and Control-Option with a three-finger swipe, are
  `center-nearest`: the nearest window in the direction the canvas would follow
  the fingers (fingers left look right) is focused and the camera flies to it
  at the current zoom, as Control-Option with an arrow key does. A four-finger
  hold, and Control-Option with a three-finger hold, are `center-window` when
  the fingers lift. Both are
  [window navigation](#window-navigation-and-native-focus), native focus
  request included. Option with a three-finger swipe on a window is
  upstream's resize: the resize grab, which has been run at the controller
  only and not through the shell.
- `set-trackpad off` (no default key; bind it, or `Infinify msg action
  set-trackpad off`) stops all of the above, the two-finger pinch included,
  until `on`, `toggle`, a config change of `[input.trackpad] enable`, or a
  restart. The pointer, clicks and two-finger scrolling stay on: they are
  macOS's.
- A malformed entry in a `[gestures]` table is reported in upstream's words,
  as every config problem is, and skipped; the rest of the file applies.

What has been run, on 2026-10-09 and 2026-10-10 (macOS 27.2, Apple Silicon,
ad-hoc signed builds), with nothing saved as evidence. **No trackpad gesture
was performed**: these were automated sessions, and touch input cannot be
injected. The first
five items were run on the gestures change by itself, before it was put together
with [Camera motion](#camera-motion); the sixth is the run of the two together,
on a tree that had neither window navigation nor managed windows, so
`center-nearest` was still refused there; the last is the run of this tree.

- Built and linked: `scripts/build-app.sh` with `trackpad-gestures.m`, no
  warnings under `-Wall -Wextra -Werror`.
- The controller's dispatch: `crates/desktop/tests/gesture_flow.rs`, synthetic
  event streams through the exported C ABI.
- The built app, one launch as `--windowed 1100x700` on a private scene, config
  and socket, driven through `Infinify msg`: a config with a `[gestures]`
  override loading with nothing on stderr; `set-trackpad off`, `on` and `toggle`
  answering `ok`, and a wrong or missing argument answering upstream's message
  with exit status 1; four malformed gesture entries each reported in
  upstream's words while the rest of that file took effect; a `[gestures]`
  value of the wrong type refused whole with upstream's TOML message while the
  previous file stayed in force; `camera`, `zoom`, `home-toggle`, `zoom-to-fit`
  and `pan-viewport` landing exactly where they did before; SIGTERM exiting 0
  with the socket removed. The trackpad's on/off state cannot be read over the
  socket, so only the answers were seen.
- The recogniser, outside the app: the scripted touch sequences of a throwaway
  command-line harness (23 sequences and a random run of 392,363 frames whose
  output stayed well formed), and a second throwaway program that fed the
  recogniser's events through the real controller library, which accepted all
  95 of them. [GESTURES.md](../../crates/desktop/GESTURES.md#integration-run-2026-10-09)
  lists what each sequence became.
- After the review's fixes (the controller's launch delay and drag identity,
  and in the shell the press ending a gesture before navigation is cancelled
  and the `cancel_navigation` after a cancelled pan): the build,
  `gesture_flow`, the socket run and the second throwaway program again, with
  the same results.
- The two together: the build, `gesture_flow` and `motion_flow` on the merged
  controller, and one more launch of about six seconds, `--windowed 1100x700`
  on a private seeded scene, config and socket. A file holding camera-motion
  settings and a `[gestures]` override loaded with nothing on stderr and its
  bookmark was read back; `set-trackpad off`, `on` and `toggle` twice and
  `toggle-cursor-pan` twice answered `ok`; `set-trackpad maybe` answered
  upstream's message with exit status 1; a second file with another override
  was reloaded with nothing on stderr; `pan-viewport`, `zoom-to-fit`, `camera`,
  `zoom` and `home-toggle` landed where they did before; `center-nearest right`
  was refused by name; SIGTERM exited 0 with the socket removed. The second
  throwaway program was not run again on the merged library.
- This tree, on 2026-10-10: the build, `gesture_flow` with the scenarios the
  merge added (a four-finger swipe and a hold running `center-nearest` and
  `center-window`, a gesture's pointer and modifier state reaching
  `focus-center` and `cycle-windows`, a window closing under a move) and the
  other controller scenarios, the headless coordinator regression, and one
  launch of 6.9 seconds, `--windowed 1100x700` on a private freshly seeded
  scene, config and socket, without Screen Recording access. A file with
  motion settings and a `[gestures]` override (a threshold, a named swipe
  bound to `cycle-windows forward`, a five-finger swipe and a three-finger
  hold) loaded with no config line on stderr and its bookmark was read back;
  `set-trackpad off`, `on` and `toggle` twice and `toggle-cursor-pan` twice
  answered `ok`; `set-trackpad maybe` answered upstream's message with exit
  status 1; `center-nearest right` flew to the seeded window at 1950 0 and
  focused it; [Camera motion](#what-has-been-run-of-camera-motion) has the
  flights of that run. No gesture event reached the app.

Only compiled, never executed: everything between a finger and the recogniser,
and between the recogniser and the controller, inside the app. That is the
views' touch forwarding, the conversion of a touch to millimetres, the hold and
finger-count timer, the magnify routing of a two-finger pinch, the modifiers,
context, output and pointer added to `gesture_begin`, the status line feedback,
the frame timer started by a coast or by the edge pan under a moved window,
what a press or a cancelled pan does to that coast, and everything the merge
with window navigation added behind a touch: the modifier state sent with an
update or an end, the focus request of a gesture reply handed to the
coordinator, hold-to-commit armed by a gesture that fires `cycle-windows`, and
the press that ends an open cycle before the gesture. Untested in any form: real fingers, how
the thresholds feel, and what macOS does with the same fingers while its own
gestures are on or off.

### Settings

Applied now:

| Config | Effect |
| --- | --- |
| `mod_key`, `[keybindings]`, `[mouse.*]`, `[bindings] disable_defaults` | the hot keys registered and the pointer dispatch above |
| `[input.keyboard] repeat_delay`, `repeat_rate`, `layout_independent` | key repeat and key lookup |
| `[navigation] pan_step`, `nudge_step`, `camera_speed` | `pan-viewport`, `nudge-window`, the speed of every camera flight |
| `[navigation] anchors` | points `zoom-to-fit` frames together with the windows, and that `center-nearest` can land on (focus is then cleared) |
| `[navigation] auto_navigate_on_click` | off by default; on, a completed click (released within 5 points of the press) on a window that is not wholly in view also flies the camera to it, when the button comes up |
| `[zoom] reset_on_activation` | on by default: a canvas window focused in its own application, or by `msg focus`, is flown to at 1:1 when it is clipped; off keeps the zoom |
| the `cycle-windows forward` binding's modifiers | the modifiers that hold a cycle open (upstream's `cycle_hold`): Option by default |
| `[navigation.bookmarks]` | the bookmarks every launch starts from |
| `[navigation] trackpad_speed`, `mouse_speed` | multiply a bound scroll pan, two-finger or wheel, and a swipe pan (1.5 by default), and a bound drag pan (1.0) |
| `[navigation] drift` | how long a released pan coasts, a swipe pan included: 0 off, 0.5 the default, 1 floatiest |
| `[navigation.edge_pan] zone`, `speed_min`, `speed_max`, `latency_ms` | the pan under a window dragged to a display's edge, by button or by gesture: the zone's width (100), points per frame at its boundary and at the edge (4 and 10), and the wait at an edge that borders another display (120 ms) |
| `[navigation.edge_pan] cursor_pan`, `cursor_zone` | cursor edge pan: on or off at launch (off), and its zone (20) |
| `[gestures.*]`, `[gestures] swipe_threshold`, `pinch_in_threshold`, `pinch_out_threshold` | what a trackpad gesture does, see [Trackpad gestures](#trackpad-gestures) |
| `[input.trackpad] enable` | whether gestures are dispatched at all, until `set-trackpad` says otherwise |
| `[zoom] step`, `fit_padding` | `zoom-in` / `zoom-out`, `zoom-to-fit`, `zoom-to-fit-snapped` and the zoom-out limit |
| `[navigation] resize_step` | the step of `grow-window` and `shrink-window` (20); see [Window sizing actions](#window-sizing-actions) |
| `[zoom] step`, `mouse_speed` | a bound wheel zooms by `step ^ (lines / 2 × mouse_speed)`, animated |
| `[zoom] trackpad_speed` | scales a pinch that zooms, of two fingers or more (1.0 by default) |
| `[snap] enabled`, `gap`, `distance`, `break_force`, `corners`, `centers` | the logical window drag and its cluster |
| `[snap] outer_gap`, `focus_placement`, `[[outputs]] focus_placement` | where window navigation and `send-to-output` park a window; an `[[outputs]]` entry is matched by display UUID, `windowed`, or `*`. `outer_gap` is also the inset of `fit-window` and `fill-window`, and `[snap] gap` the clearance `fill-window` keeps from other windows |
| `[[outputs]] hot_corners` (`top_left`, `top_right`, `bottom_left`, `bottom_right`, `threshold`, `disable_while_dragging`) | [hot corners](#displays-hot-corners-layouts-and-autostart) |
| `autostart` | commands run once at launch |
| `[session] restore_camera`, `restore_bookmarks` | what a restart restores, see [Persistence](#persistence-and-lifecycle) |
| `window_placement` | where a window that appears by itself is placed: `center`, `cursor` or `auto` |
| `[zoom] reset_on_new_window` | whether the camera's flight to a new window lands at 1:1 |
| `[navigation] auto_navigate_on_close` | whether the camera flies to the window that takes the focus after a close, when that window is docked to the closed one or overlaps it and is not wholly in view |
| `[session] suspend_on_close`, `restore_windows`; the same two keys of a `[[window_rules]]` entry, matched by bundle identifier as `app_id` and by `title` | whether a window that closes by itself leaves a stand-in; whether a saved slot whose window is gone stays as one after a discovery pass, at launch or when the canvas reopens. See [Managed windows](#managed-windows) |
| `[[window_rules]] app_id`, `title`, `position`, `widget`, `pinned_to_screen`, `output`, `focus_on_open`, `opacity` | per-window policy for a window that appears, see [Window rules](#window-rules-widgets-and-pinned-windows) |
| `[[window_rules]] pass_keys`, `pass_mouse` | the key bindings a focused window takes from Infinify, and the mouse bindings the window under the pointer takes, see [Passing keys and presses](#passing-keys-and-presses-to-an-application) |
| `[background] type`, `path`, `texture`, `mirror_tile`, `transparent_shader`, `animate_fps`, `cache_shader`, `cache_budget_mb` | the canvas behind the windows: DriftWM's dot grid, a GLSL shader (upstream's `extras/wallpapers` work as they are), a tiled image, a wallpaper fixed to the view, or nothing. A leading `~/` in a path is expanded. PNG and JPEG, and as a tile a tiled pyramidal TIFF of any size. `cache_shader` bakes a static shader into textures, and `cache_budget_mb` bounds each display's cache of those and of TIFF chunks; on a Retina display the default 128 is too small for a baked shader around the canvas origin, and 256 or more is the value to set. See [Rendering](#rendering) and [Background caches](#background-caches) |
| `[decorations] border_width`, `border_color`, `border_color_focused`, `corner_radius`, `shadow`, `opacity`, `opacity_focused`, `default_mode` | the border, corner clip and shadow of every window and stand-in, and the opacity of every window that has none of its own from a rule or `msg opacity`: `opacity_focused` for the one holding the canvas's logical focus, `opacity` for the others, both 1 by default (a stand-in is always opaque, as upstream's); `default_mode` is `client`, `minimal` or `none` (`server` only through a window rule, as upstream) |
| `[decorations] bg_color`, `fg_color`, `title_bar_height`, `font`, `font_size`, `font_weight`, `title_align` | the chrome the compositor draws itself: stand-ins, and the title bar of a window a rule made `server`. `title_bar_height` is also the diagonal step of the placement cascade |
| `[[window_rules]] decoration`, `border_width`, `border_color`, `border_color_focused`, `corner_radius`, `shadow`, `opacity` | the same per window, from the rule the window matched when it reached the canvas (bundle identifier as `app_id`, and `title`), kept until it is gone; never for a stand-in |
| `[decorations] blur`, `[[window_rules]] blur` | the frost behind every window, or behind the window the rule matched when it reached the canvas; never behind a stand-in. See [Blur, window animations and the error bar](#blur-window-animations-and-the-error-bar) |
| `[effects] blur_radius`, `blur_strength`, `animate_blur_fps` | the frost: its number of blur passes (2), their spread (1.1), and how often it is refreshed over an animated background (20 a second; 0 never; 144 at most) |
| `[effects] animation_speed`, `animation_scale` | the open and close animations and the stand-in fades: the share of the remaining way covered per 60 Hz frame (0.5; 1 is instant) and the scale they grow from and shrink to (0.95; 1 fades only). Upstream's move, resize, fit and fullscreen animations, which the same two keys drive, do not exist here |
| `[output.outline] color`, `thickness`, `opacity` | the outline of every other display's view of the canvas; thickness 0 draws none |
| `[zoom] fit_padding` | also the margin of `msg screenshot all` |
| `focus_follows_mouse` | off by default; on, the window under a moving pointer takes the focus without being raised, see [Pointer motion, sloppy focus and pick mode](#pointer-motion-sloppy-focus-and-pick-mode) |
| `[zoom] interact_min` | 0 (off) by default; below that zoom a window on the canvas is one pick target: a click flies to it, a drag moves it and nothing reaches its application. A screen-pinned window and a widget are not picked and keep their pointer |
| `[env]` | the environment of commands run by `exec`, `spawn`, `exec-terminal`, `exec-launcher` and `autostart`; its `PATH`, when set, is also where a default binding's program is looked for, and its `INFINIFY_SOCKET`, when set, replaces the one the app adds |

`exec` and `spawn` run their command as `/bin/sh -c`, detached in a session of
their own with standard input and output on `/dev/null`; the app never waits for
it. Upstream's Wayland toolkit variables (`QT_QPA_PLATFORM` and four others) are
left out of that environment unless `[env]` sets them. Where upstream adds
`WAYLAND_DISPLAY`, from which its `msg` finds the socket, the app adds
`INFINIFY_SOCKET`, the socket it serves, unless `[env]` sets it or the app runs
without IPC: a command it starts reaches this instance with a plain
`Infinify msg …`, whichever `--socket` the app was given.

Read and validated by upstream's parser, then unused because the feature does
not exist here: `[navigation] touch_speed`, `[zoom] touch_speed`,
`[input.keyboard]
layout`, `variant`, `options`, `model`, `remember_layout_per_window`, `num_lock`
and `caps_lock` (macOS owns the input sources and the lock keys), the rest of
`[input.trackpad]` (macOS owns the device), `[input.mouse]`, `[input.touch]`,
`[input.tablet]`,
`[cursor]` (theme and size reach only the environment of a run command),
`[backend]`,
the rest of `[output]`, `[[outputs]]` `scale`, `transform`, `position` and
`mode` (macOS owns the display arrangement), the rest of `[[window_rules]]`
(`preserve_aspect_ratio` and `layer_order` are kept with the window and
change nothing, and so are `size` and `fullscreen` in a default launch;
`hot_corners.disable_when_fullscreen` has nothing to suppress there either),
`[touch.*]`, and `[mouse] resize_on_border` and the decoration settings.

### Removed fixed gestures

Normal runs no longer have Option-drag or Option-scroll pan, Command-scroll
zoom, or Control-Option-drag move with Shift for the cluster. Their DriftWM
equivalents are in the tables above: Control-Option-drag or -scroll pans,
Control-Option-wheel zooms, Option-drag moves a window. Two more things changed
with them: a mouse wheel on empty canvas now zooms where every scroll there
used to pan, and a two-finger scroll pans 1.5 times the finger's travel
(`navigation.trackpad_speed`) where it used to pan 1:1. Control-Option-click on
a detached placeholder survives only while no binding claims it (see Controls).
The fixed pinch zoom is gone from normal runs as well: a two-finger pinch is the
`2-finger-pinch` gesture binding, which zooms on empty canvas and, over a
window, only with Control-Option held (see
[Trackpad gestures](#trackpad-gestures)).

### What has been run

`crates/desktop/tests/config_flow.rs` drives the controller side through the
exported C ABI. On 2026-10-09 the built app (ad-hoc signed, macOS 27.2, Apple
Silicon) was also launched twice as `--windowed 1100x700` with its own
`--state`, `--config` and `--socket` on a seeded scene of three detached
placeholders and driven through `Infinify msg`; nothing from those runs is
saved as evidence. Observed there, each read back over the socket:

- no config file: bookmarks `1` to `4` at the four corners, `pan-viewport right`
  moving the camera 100 points, `zoom-in` from 0.5 landing on 0.55, and
  `zoom-to-fit` on 0.2848… (padding 80);
- the file then created by rename, with no restart and no request: the bookmark
  list became the file's single `desk`, the pan step 250, `zoom-in` from 0.4
  landing on 0.6 (`step = 1.5`), `zoom-to-fit` 0.3212… (`fit_padding = 20`),
  and `go-to-bookmark desk` landed on its point;
- the file edited in place (pan step 60 applied, and the warning for a `mod3`
  binding on stderr), then `reload-config` printing that warning again;
- a file with a syntax error: upstream's TOML message on stderr, the previous
  pan step and bookmarks still in force, the app still answering;
- the file, now with `restore_bookmarks = true`, moved away and 0.8 s later
  moved back unchanged, after bookmarks `1`, `desk` and `here` had been set at
  runtime: upstream's `config: failed to read …: No such file or directory (os
  error 2)` on stderr from the watch and again from `reload-config`, the pan
  step still 250 while the file was gone, and the three bookmarks unchanged in
  the registry and in the scene file before, during and after;
- `nudge-window right` moving the focused placeholder 40 points with
  `nudge_step = 40`, and `up-left` 28 on each axis;
- `spawn touch FILE` creating the file, and an `exec` whose command wrote its
  environment showing the `[env]` variable and none of the Wayland toolkit
  ones;
- `unknown action: frobnicate` and `action not implemented on macOS yet:
  close-window`, each with exit status 1 (`close-window` has run since the
  [managed windows](#managed-windows) work); SIGTERM exiting 0 with the socket
  removed;
- a second launch on the scene that run saved, with no config file: the camera
  at a new output's pose (`msg camera` 550 -318, where the file held the view
  centred on 520 -360), the four corner bookmarks instead of the file's three,
  and a bookmark set at runtime left out of the save, which carried the file's
  three forward.

The hot corners, the two display actions, keyboard layouts, the event stream,
autostart and the Linux-command rule were built together and launched twice more
that day, again as `--windowed 1100x700` on a private scene (three seeded
placeholders), config and socket. The config held `autostart = ["touch FILE"]`
and a `name = "*"` output with `top_left = "zoom-to-fit"`. Nothing from those
runs is saved as evidence. Observed, each over the socket or in the file system:

- **Autostart.** The file was there when first looked for, 1.2 and 1.5 s after
  the two launches. Deleted, it was not
  created again by `reload-config`, nor by an edit of the config file that the
  watch picked up. Two further launches after the review fixes, set up the same
  way: an autostart `printenv INFINIFY_SOCKET` wrote this instance's `--socket`
  path, once with the variable unset in the launching shell and once with
  another path set there; an autostart `Infinify msg --json layout` with no
  `--socket` was answered by this instance (`{"Ok":{"Layout":"British"}}`);
  `msg action exec printenv INFINIFY_SOCKET` wrote the same path, and, after an
  `[env] INFINIFY_SOCKET` entry was added to the file and reloaded, the file's
  value. The flag file was again created once and not after the reload.
- **Layout.** `msg layout` printed `British`, `msg layout --short` printed `en`,
  and `msg state` and every event line carried both, so the launch report
  reached the controller. That machine has one input source enabled:
  `switch-layout next` answered `ok` and the layout was `British` before and
  after. No input source was ever selected by the app.
- **Event stream.** `msg --json subscribe` and a raw client on the same socket
  received byte-identical lines; the raw one began with `{"Ok":"Ok"}` and the
  state in upstream's member order. One line while idle. `camera 100 100`: 21
  lines, one per frame, the last exactly `[100.0,100.0]`, then none.
  `zoom 0.5`: 17 lines ending at 0.5, and `zoom-in` from there 11 ending at
  0.55, the count unchanged 0.4 s after each. `zoom-in` at 1:1 (the limit),
  `state`, `send-to-output right`, `reload-config` and `switch-layout next`:
  none. Setting a bookmark that became the active one: one line
  (`active_bookmark`), deleting it: one. `focus --id 1`: one line (`is_focused`), then 16 for the flight. No
  two adjacent lines were equal. With eight subscribers connected a ninth was
  refused with the message above and status 1, in both output forms, while other
  requests were still answered; after one subscriber was killed a new one was
  admitted. A subscribed connection that then sent `"State"` got its reply as a
  whole line between events, and a second `"Subscribe"` on it got the ack and
  the state again. Six subscribers left alone ended with identical 51-line
  transcripts. On SIGTERM the app exited 0, `msg subscribe` exited 0 and the
  socket was gone.
- In the first of the two runs 33 more lines were camera changes in steps of
  1/256 point that no command had asked for, in three bursts shaped like a
  two-finger scroll with momentum. The machine's own scroll input reaching the
  panel, which pans the canvas, is the likely cause and was not confirmed; the
  same was suspected in the earlier runs under [Scripting](#scripting-ipc).
  Each of those pans was reported as an event, which is what the stream is for,
  and they are the reason the per-command counts above are quoted from quiet
  stretches and from the second run, which had none. The zoom stayed at 1
  through all of them, so the bound top-left corner (`zoom-to-fit`) did not
  fire during them.
- **Display actions with one display.** With window 1 focused,
  `send-to-output right` answered `ok` and `msg move --id 1` read `520 -360`
  before and after. `send-cursor-to-output right` answered `ok`. Nothing was
  warped: with one display the controller returns no pointer effect.
- `toggle-fullscreen` and `fit-window` were still refused as not implemented.
  `spawn` of a program that does not exist answered `ok` and the app went on
  answering; the status-line note for it was not looked at.
- The config with the hot corner loaded with nothing on stderr. Read through
  the same controller library with one output named `windowed`, that config
  reports `"corners":{"top_left":"zoom-to-fit"}` with threshold 4, and with no
  config file it reports ⌃⌥L as `exec /usr/bin/pmset displaysleepnow` with
  `"upstream":"spawn swaylock -f -c 000000 -kl"`, 45 keys, no media key and 12
  skipped. None of the five Linux programs is on that machine's `PATH`.

Not run in those launches, and so compiled and reviewed only: any hot corner
firing (no pointer was moved into a corner, and whether the shell had armed the
corner cannot be read over the socket); the pointer warp (it needs a second
display); an input source actually being selected, and the report after the
input source changes (they need a second enabled source); `send-to-output`
moving a window to another display; the ⌃⌥⇧⌘-arrow hot keys (`--windowed`
registers none); `/usr/bin/pmset displaysleepnow` (it would have blanked the
displays); the `sh could not run` note and the end of a key repeat; a subscriber
dropped after 30 stalled seconds and one kept beyond 30 quiet seconds (each run
lasted under 30 s; the server file alone was driven through both in a scratch
harness by its author, with the idle time shortened to 2 s); `subscribe` before
the canvas opens and after Return to desktop; autostart in a launch that shows
the chooser; and every one of these with a bound source.

Not run at all: hot key registration and delivery, key repeat, any pointer
press, drag or scroll (the dispatch table above is what the controller answers
to the lookups the shell sends at each config load, as logged from a scratch
build of the same sources; no real press, drag or scroll was made), right and
middle button delivery to an application, key lookup inside the app on a
non-US layout or after an input-source change (the lookup code alone was linked
into a scratch harness and pointed at the installed US, British, German, French,
Dvorak and Russian layout tables, registering nothing),
`--super` with any value, `exec-terminal` and `exec-launcher`, the status line,
tooltips and anything else drawn, the default config path, and every one of
these with a bound source or more than one display.

### What has been run for tap bindings

On 2026-10-10, macOS 27.2, Apple Silicon, one display (2056 × 1329 points, a
menu bar of 39, the Dock hidden), from agent sessions with neither privacy
grant. Nothing from any of it is saved as evidence.

Tap bindings were built together with a second shell file, `usable-area.m`,
which read `NSScreen.visibleFrame` and sent it as each output's usable
rectangle. That file was removed before the work landed, on the owner's
decision that the canvas reserves nothing
([The usable area](#the-usable-area)). The first build below still held it;
what was run of it is at the end of this section.

**The first build.** `scripts/build-app.sh` built and ad-hoc signed the app
with the controller and both shell files in it, with no warning under
`-Wall -Wextra -Werror`. It was launched once, for four seconds, as
`--windowed 1100x700` with its own `--state`, `--config` and `--socket` on a
seeded scene of three detached placeholders, and driven through `Infinify msg`.
A windowed run watches no tap, and in that build it sent no usable rectangle
either, so this launch shows that the rest is as it was and that the
controller's tap table is reached, and nothing more:

- The config was `[keybindings]` with `"alt+shift" = "switch-layout next"`.
  The app's stderr at launch held one line, the one about Screen Recording
  access: the warning the controller used to give that entry,
  `tap-modifier bindings are not supported on macOS`, was not printed (the
  build before this one was not launched beside it to see it printed).
  `msg action reload-config` answered `ok` and added no line.
- The file was then rewritten in place with two more taps, `"mod" =
  "home-toggle"` and `"ctrl+alt" = "zoom-reset"`, which land on one chord under
  the default super chord. stderr gained `binding 'mod' = 'home-toggle'
  skipped: 'ctrl+alt' already holds this macOS chord`, once from the file
  watch and once from `reload-config`. That line comes from the controller's
  tap table through the shell's binding refresh, so both ran in the app. The
  `bindings` reply itself is not reachable over `msg`: which taps the shell
  was handed was not read back.
- `msg state` reported the three placeholders at `[520, -360]`, `[1950, 0]`
  and `[-620, -890]` and one output `windowed` of 1100x636 at camera
  `550 -318`, zoom 1. `action center-nearest right` settled on camera
  `1950 -0`, the Browser placeholder's centre, and `action zoom-to-fit` on
  zoom `0.28484848484848485`, camera `750 -390`: the numbers recorded for
  earlier builds on the same seed.
- A viewport screenshot (`msg screenshot -o`) was written and looked at: the
  three placeholders on the dot grid at that zoom.
- SIGTERM ended the app with status 0 and its socket file was gone.

**The build that landed.** The tap tracker beside the display-link frame
timer and the lost-input check ([Camera motion](#camera-motion)), and no
`usable-area.m`: `scripts/build-app.sh` compiled it with no warning under
`-Wall -Wextra -Werror`, and it was launched once, for three seconds, the same
way on the same seed, with the `alt+shift` config:

- stderr held the one line about Screen Recording access, before and after
  `msg action reload-config`, which answered `ok`. The two-tap collision file
  was not tried again.
- `msg state` reported the same three placeholders and the output `windowed`
  of 1100x636 at camera `550 -318`, zoom 1; `focus` answered `(none)`.
- `action center-nearest right` settled on camera `1950 -0` with `focus`
  naming window 2; `action zoom-to-fit` on zoom `0.28484848484848485`, camera
  `750 -390`, and a second one back on zoom 1, camera `1950 -0`;
  `action pan-viewport right` on camera `2050 -0`. Each was read back until
  two reads agreed: the flights arrived, ticked by the frame timer or by the
  poll that stands in for it, which a socket does not tell apart.
- A viewport screenshot (`msg screenshot -o`), 1100x636, was written and
  looked at: the Browser placeholder, 900x600 and 100 points left of centre,
  on the dot grid.
- SIGTERM ended the app with status 0 and its socket file was gone.

No key was tapped in either launch, and a windowed run installs no monitor:
neither shows a tap.

**The two sides joined outside the app.** Since a windowed launch does not
reach the tracker, a throwaway program outside the repository linked the
release controller library with `tap-keys.m` as it is in the tree (and with
`usable-area.m`, then still there), and did in one process what `main.m` does
with it. It opened no window, installed no monitor and posted no event:

- With the `alt+shift` config loaded, the controller's `bindings.taps` (one
  entry, Option-Shift, `switch-layout next`) was handed to `DWTapKeys`, and
  its tracker was given `flagsChanged` events built in memory, each stamped
  with the moment it was built: Option down, Shift down, Shift up fired once, the `tap` command went to the controller
  with the entry's own `modifiers`, a `pointer` and `held: true`, and the
  reply carried the `switch_layout` effect; Option up fired nothing more.
  Control alone, which nothing is bound to, fired nothing, and neither did
  the same chord with `-taint` called before the release. A `tap` on Control
  sent by hand was refused with `no tap binding on ⌃`. No input source was
  switched: nothing performed the effect.

**Before the app was built**, by the session that wrote the shell side, in
throwaway programs that are not in the tree and were not run again against the
built app:

- `tap-keys.m` as it then was, linked alone into a throwaway program that
  installs no monitor and posts nothing: its tracker was handed `flagsChanged`
  events built in memory. Upstream's own test cases (a clean chord, a taint, a
  single modifier, the peak chord), no second fire while a modifier stays
  down, Caps Lock, Fn, two Shifts, an unbound chord, an entry marked not
  implemented, and a change that adds one modifier and removes another each
  fired what they should and nothing else.
- The event counters were read, twice, 1.5 seconds apart, and nothing else was
  done to them: none moved between the two reads, and key down and key up
  stood within two of each other out of 206 thousand, which is what they would
  show if a held key's repeats are not counted as presses. No key was held to
  see that.

**The tracker as it is now.** `tap-keys.m` has since come to count the
system-defined events and to ask the session, as a chord begins, when it last
saw each counted kind. As it is in the tree it was linked alone into the same
kind of throwaway program, which installs no monitor and posts nothing, and
handed the same events, each stamped with the moment it was built, as a real
one is with the moment it happened:

- Every case in the list above fired what it should and nothing else.
- A chord whose first change was stamped five seconds in the past, the session
  having seen no key, button or system-defined event for eleven, fired. One
  stamped a second before the last of those events fired nothing, twice
  running, and the clean chord after it fired. A change stamped 0 fired
  nothing.
- The session was only read for this, and nothing was pressed for it.
  System-defined events stood at 167,921 against 158,143 mouse button changes,
  9,778 more, with 28,497 modifier changes. Through two watches, of 12 and of
  240 seconds, in which no key or button was pressed, the system-defined count
  did not move. The owner then worked for seven minutes under a third, which
  read the counts about every five milliseconds: of 244 reads in which a
  modifier had changed and no key or button had, none saw the system-defined
  count move; in 236 it moved with the buttons and by as much; in four it
  moved alone and in four a button moved without it, which is what a copy and
  its button on either side of a read would show. Over the quarter of an hour
  around that, nine system-defined events beyond the buttons' were counted,
  and what they were was not seen. Apple's headers (`IOLLEvent.h`,
  `ev_keymap.h`) give one to the volume, brightness and media keys and to no
  modifier but Caps Lock, outside Sticky Keys and Slow Keys. The last
  system-defined event stood about 20 microseconds before the last button
  release. A kind never seen (the other mouse buttons, at 0) reads as last
  seen 124 seconds after startup, long ago and not just now, and two reads in
  a row agreed to two microseconds.

Not run: a normal, full-screen run with these changes, which is the only kind
that watches a tap. No modifier was
pressed for any of this: no monitor has delivered an event, the counters were
seen to move only between two reads, under the owner's own work, the app has
sent no `tap` and no tap has run an action in it; nor a tap under a hot key, a
scroll, a gesture or Caps Lock on a keyboard; whether a hot key's own key
press moves the key-down counter (the shell cancels the tap itself when one
fires); what an untrusted process is sent beside a trusted one. No volume,
brightness or media key was pressed, so that one moves the system-defined
count is read from Apple's headers and not seen. No real event's timestamp
was set beside `systemUptime`, which Apple documents as the same seconds
since startup: if an event's ever reads older than it is, the chord it begins
is taken for one with a key on top, no tap fires and nothing says so. No
chord was begun under a busy main thread. Nor was a chord held while the
lost-input check ended a press whose release never arrived: what that does to
the session's button counts was not looked at.

**The removed usable-area file.** `usable-area.m` never ran in the app: the
one launch of the build that held it was windowed, where it sent nothing. In
the throwaway programs above, linked alone, it gave the whole output for the
display here ({0, 0, 2056, 1265}, an output then being its display less the
64-point strip: the strip is taller than the menu bar and
the hidden Dock takes nothing) and the rectangles worked out by hand for
stand-in screens; joined to the controller, the display's output registered
with that rectangle, and a hand-made one 80 points shorter was taken by
`set_usable_area`, after which `set-bookmark` at camera `0 0` stored the point
`1028 -592.5`, the centre of the shorter rectangle. That is the controller's
side answering, which stays in the tree and is inert while the shell sends no
rectangle; none of it describes the app as it is.

## Camera motion

A normal run moves the camera the way DriftWM does: a flick drifts, a window
dragged to the edge pans the canvas under it, a pointer pushed against an edge
can pan the view, and the pointer's pan and zoom speeds come from the config.
The physics and the numbers are the controller's
([MOTION.md](../../crates/desktop/MOTION.md)): momentum is upstream's own
`MomentumState` from `driftwm-core`, and edge pan, cursor edge pan and the
pointer zooms are adapted from the pinned upstream source. The shell only says
when and where. It stamps each pan with its event's time and source, tells the
controller when a pan ends, passes the pointer along with a window drag,
reports the pointer while cursor edge pan asks for it, and keeps its frame
timer running for as long as the controller reports motion: a flight, a
drift, an edge pan or a cursor pan alike. The frame timer is a display link
at the display's refresh rate ([Rendering](#rendering)), 120 Hz on a ProMotion
display. Each frame is the navigation
coordinator's tick, the one that flies
[window navigation](#window-navigation-and-native-focus), watches the hot
corners and, while a `msg subscribe` client is connected, is followed by at
most one [State event](#event-stream). Ahead of the tick a frame reads the
pointer once, if anything wants it, for the two things that do: the
[hover](#pointer-motion-sloppy-focus-and-pick-mode) a moving pointer has
waiting, which goes with the frame, and then cursor edge pan's report. The
same timer redraws an animated `[background]` ([Rendering](#rendering)); kept
running by that alone it ticks nothing, and the camera and the hot corners are
the idle poll's as before, but each of its frames still reads the pointer the
same way: a waiting hover goes with a frame whenever this timer runs, whatever
keeps it running, and with a timer of its own only when it does not. A
[trackpad gesture](#trackpad-gestures) needs none of that from the shell: its
events carry their own times, and the controller makes the same pans, launch,
pinch and drag of them itself, so a swipe drifts and a moved window edge-pans
by the rules below. There is no
new flag. `--demo`, the probes and the owned-resize modes read no config and
move exactly as before.

What you will notice:

- **A released pan drifts.** Lift the fingers from a two-finger scroll or a
  three-finger swipe, or release a drag pan, while the canvas is moving and the view keeps going,
  slowing until it stops. `navigation.drift` sets how far (0.5 by default, 1
  floatiest, 0 off); a reload reaches a drift already under way. The launch
  speed is that of the last 80 ms of movement. A drag pan that rested for
  50 ms or more before its release flings nothing, and one that rested that
  long and then moved again flings only the movement after the rest. Two fingers that stop on the
  trackpad and stay down are treated as upstream treats them: 50 ms after
  their last movement the drift starts under them, and lifting them ends it.
  Three fingers that stop mid-swipe hold the view still instead, and lifting
  them 50 ms or more after their last movement flings nothing.
  A press on the canvas, a bound pinch or swipe, a new pan, a wheel zoom, or
  any hot key, hot corner, gesture-fired action or `Infinify
  msg action` aimed at that display stops the drift, and so does any flight
  that starts there: a click that brings a clipped window into view, a new
  window, the window that takes the focus after a close.
- **macOS's inertial scrolling no longer pans the canvas.** The events macOS
  adds after the fingers lift are dropped for a scroll that panned, because the
  drift is computed from the fingers' own movement, as upstream does it. Until
  now those events were the only coasting there was, so what follows a flick is
  DriftWM's curve instead of the system's. A scroll forwarded to an application
  is passed on whole, inertia included. When a window comes under the pointer
  during a scroll that began by panning and takes it over, the rest of that
  scroll is the window's too, its end and its inertia with it.
- **Pan and zoom speeds are the config's.** A scroll pan and a swipe pan are multiplied by
  `navigation.trackpad_speed` (1.5, as before) and a drag pan by
  `navigation.mouse_speed` (1.0, so unchanged unless you set it). A wheel zooms
  by `zoom.step ^ (lines / 2 × zoom.mouse_speed)` as before, but now glides to
  its target the way the zoom keys do, and notches that arrive mid-glide add
  up. A pinch that zooms (which the `[gestures]` tables decide, see
  [Trackpad gestures](#trackpad-gestures)) is scaled by `zoom.trackpad_speed`
  (1.0) from the zoom it began at, and one that ends within 0.05 of 1:1 snaps
  to 1:1.
- **Pointer zoom stops where zoom-out stops.** Wheel and pinch no longer go
  down to 0.001: their lower limit is half the zoom that fits every window, and
  a view already further out is pulled up to that limit by the next notch or
  pinch.
- **A window dragged to the edge pans the canvas.** While a window, or with
  Shift its cluster, is being moved and the pointer is within
  `navigation.edge_pan.zone` (100 points) of an edge of the display the drag
  began on, the view pans toward that edge and the window stays under the
  pointer: `speed_min` (4) points per frame at the zone's boundary rising to
  `speed_max` (10) at the edge. It keeps panning while the pointer rests there
  and stops when the pointer leaves the zone or the button is released. At an
  edge that borders another display the pan first waits `latency_ms` (120). A
  window moved by gesture (three-finger tap, then three-finger swipe) pans the
  same way once the swipe has carried it to the edge: the gesture has a pointer
  of its own that stops there, one point short of the edge.
- **Cursor edge pan.** Off unless `navigation.edge_pan.cursor_pan = true` when
  the app starts. Control-Option-E (`toggle-cursor-pan`, or `Infinify msg
  action toggle-cursor-pan`) flips it for the run; a config reload does not, as
  upstream reads the key once at startup. While it is on, a bare pointer within
  `cursor_zone` (20 points) of an edge of a display's view pans that view at
  `speed_max` points per frame. The pointer counts only where a press would
  reach the canvas panel, so a panel behind another window does not pan; that
  is the same reading of the pointer a hover is sent with. Cursor edge pan
  does not hold the pointer: with `focus_follows_mouse` a pointer that moves
  inside the zone still focuses the window the pan brings under it. While
  a button is held in a canvas panel, for a drag in a captured window as much
  as for a canvas gesture, nothing new starts: a pan already running when the
  button went down keeps going, as upstream's does under a grab, and one that
  was not running waits for the release.
- **⌃⌥E is taken** while a canvas panel is open, like the other registered
  chords. Bind `"mod+e" = "none"` to give it back.

Where this differs from DriftWM, or is rough:

- The toggle shows nothing: no status message, and its state cannot be read
  over the socket.
- A view's edge is the edge of its output, which is the display's own edge.
  The top zone therefore lies under the menu bar, and a zone the Dock covers
  under the Dock: no output is reported for a pointer there, because a press
  would not reach the panel, so pushing the pointer against the top of the
  screen pans nothing. A `cursor_zone` taller than the menu bar leaves a band
  below it that does. Read from the code, not run. (Until 2026-10-10 the output
  began 64 points down, under the toolbar strip, and the top zone was the 20
  points below that.)
- While nothing moves the pointer is looked at about every 80 ms, so a cursor
  pan can start that late. Once it runs it is checked every frame.
- The frame timer follows the display, and what that changes is upstream's
  own rule for each kind of motion. A flight (window navigation, a view
  action, a wheel zoom) and a coast are scaled by each frame's elapsed time,
  so they take the same time at 120 Hz as at 60 Hz and are only drawn twice
  as often. Edge pan speeds are per frame, as upstream's are (`px/frame` in
  its config reference, and no elapsed time in its `tick_edge_pan_on`): on a
  120 Hz display `speed_min` 4 and `speed_max` 10 are 480 and 1200 points a
  second where they were 240 and 600 on the 60 Hz timer, exactly as DriftWM
  pans twice as fast on a 120 Hz monitor. Halve the two in
  `[navigation.edge_pan]` for the old pace. A display in low power mode may
  refresh, and so pan, at 60.
- **A move that nothing holds any more is ended** (a macOS platform rule; a
  Wayland grab cannot lose its release, and libinput ends every gesture it
  begins). A window move whose end is lost would be held for good: the
  controller refuses every flight while a drag is installed, and a move
  resting in the edge zone goes on being carried by the pan beneath it, a
  frame's worth every frame, without bound. Every frame and every poll
  therefore look. A press whose button macOS reports up for 50 ms while its
  gesture is still held (released over another application, inside a menu or
  a drag session of macOS, or while the panels were rebuilt), and whose
  release is not waiting in Infinify's event queue, is released at the
  pointer through the path a real release takes: a pan launches, a move or a
  resize ends, a press in a captured window gets its button back. The queue
  is looked at because the 50 ms are wall time: after a slow poll a real
  release may still be waiting behind that reading, and it then ends its
  press itself, at its own point and time, so a flicked pan keeps its coast.
  A trackpad gesture of three or more fingers ends cancelled when the canvas
  is no longer what a press at the pointer would reach (Mission Control,
  another window, a menu), since its touches are then not the panel's; and a
  move gesture whose fingers have sent nothing at all for thirty seconds is
  taken for lost. Still fingers send nothing either, so thirty seconds is
  also the longest a move gesture can rest in the edge zone without the
  least movement of a finger; the move then ends where it is, and those
  fingers begin no other gesture until they lift. Each says so once on
  stderr.
- A drag stays on the display it began on: a pointer that has left it pans
  nothing, and the window does not cross into another display's view.
- A wheel or pinch zoom during a window drag does nothing: the controller
  refuses a wheel zoom, so the shell drops the input, and no trackpad gesture
  begins while a button is held. It used to zoom, and upstream
  zooms under a grab. Only the edge pan carries a dragged window: a scroll pan
  during a drag moves the view and leaves the window where it is in the world.
- A scroll during a held drag pan pans, but only the release launches the
  drift. If the fingers lift first and the button comes up within 50 ms of
  their last movement, that scroll is part of the fling; upstream's lift would
  already have spent it.
- Resting two fingers on the trackpad does not stop a drift the way it stops
  macOS's own inertia. Moving them, or a press, does.
- A lift counts as a rest when macOS stamps it 50 ms or more after the last
  movement of that scroll. Whether a real flick's lift always arrives sooner
  has not been tried; if it does not, flicks would not drift.
- With two-finger scroll bound to zoom (not the default), macOS's inertia
  events still zoom: they are dropped for pans only.
- A drag pan is not held inside its display as upstream's pan grab is, and
  upstream's `continuous` scroll source is never reported: a scroll with
  precise deltas counts as a finger, anything else as a wheel.

### What has been run of camera motion

`crates/desktop/tests/motion_flow.rs` drives the controller side through the
exported C ABI in nine scenarios: a flick's drift compared step by step with
upstream's `MomentumState`, the drift setting, everything that stops a drift,
an untimed pan never drifting, the pan under a dragged window and its cluster,
the wait at an edge that borders another output, cursor edge pan with the
toggle, the wheel zoom and the pinch; `gesture_flow.rs` drives a swipe, a pinch
and a move gesture into the same code. `tests/e2e/desktop-navigation.sh`, the
headless coordinator regression, still passes on the new frame tick. The 50 ms
launch delay (`pan-launch.m`) was run by itself in a throwaway harness: one
launch 54 ms after a lone pan, none during a burst of pans 10 ms apart and one
about 50 ms after its last, an immediate launch on an explicit end, and none
after a cancel.

On 2026-10-09 the app built from these sources (ad-hoc signed, macOS 27.2,
Apple Silicon) was launched once, for 7.7 seconds, as `--windowed 1100x700`
with its own `--state`, `--config` and `--socket` on a seeded scene of three
detached placeholders and driven through `Infinify msg`; nothing from the run
is saved as evidence. An earlier build of this change had been run the same
way; what follows is the run of these sources. Observed there:

- a config file setting `drift`, both pan speeds, all six
  `[navigation.edge_pan]` keys and the three `[zoom]` keys accepted at launch
  with nothing on stderr;
- `action toggle-cursor-pan` answering `ok` with exit status 0, twice (until
  now the action was refused as not implemented). In the half second between
  the two, while cursor edge pan was on, the camera did not move and the app
  kept answering. That shows the toggle was accepted and nothing more: the flag
  was not read back, since nothing on the socket carries it, and whether the
  shell's pointer reports reached the controller in that time was not
  observed;
- the frame tick, which now runs momentum and edge pan before each flight,
  leaving flights exact: `pan-viewport right` moved the camera from 550 to 690
  (`pan_step = 140`), `zoom 0.5` then `zoom-in` landed on 0.6 (`step = 1.2`)
  and `zoom-reset` on 1, `home-toggle` went to the origin and back to
  690 -318, `zoom-to-fit` to 0.2848… and back, `go-to-bookmark 1` from the
  origin to the 690 -318 that `set-bookmark 1` had stored, and `camera 0 0` to
  the origin;
- the file replaced by rename with another drift, other speeds and edge pan
  values and `pan_step = 260`: the next `pan-viewport right` moved 260 with no
  restart, `reload-config` answered `ok`, and stderr stayed empty;
- `debug-counters` answering, and SIGTERM exiting 0 with the socket removed.

That run was of this change by itself. After
[trackpad gestures](#trackpad-gestures) were put on the same controller code
the merged app was launched once more, for about six seconds, in the same way:
`toggle-cursor-pan` answered `ok` twice again, a file with motion settings and
a `[gestures]` override loaded and was replaced and reloaded with nothing on
stderr, and `pan-viewport right` (100 points, then 200 canvas points at zoom
0.5), `zoom-to-fit` (to 0.2848… and back), `camera 400 -250`, `zoom 0.5` and
`home-toggle` landed exactly; SIGTERM exited 0 with the socket removed.

Those runs were of a tree without window navigation, hot corners, the event
stream or managed windows. On this tree the frame is the navigation
coordinator's tick, and on 2026-10-10 its build was launched once, for 6.9
seconds, in the same way (private seeded scene of three detached placeholders,
config and socket, `--windowed 1100x700`, no Screen Recording access, so
stderr held the not-managed line and nothing else). Observed through
`Infinify msg`: `state` listing the three windows with the camera at 550 -318;
`center-nearest right` landing on 1950 0 with the Browser placeholder focused;
`pan-viewport right` on 2050 0; `zoom-to-fit` on 750 -390 at 0.2848… and back
on 2050 0 at 1; `home-toggle` on the origin and back on 2050 0; a config file
with `drift`, both pan speeds, two `[navigation.edge_pan]` keys,
`zoom.trackpad_speed` and a `[gestures]` override accepted at launch;
`toggle-cursor-pan` answering `ok` twice with the camera unmoved in the 0.4
seconds between; `set-trackpad` answering as before; then `pan-viewport left`
on 1950 0, `center-nearest left` on the Notes placeholder at 520 -360,
`center-window` staying there at zoom 1, `zoom-in` and `zoom-reset` leaving 1,
`cycle-windows forward` answering `ok` and changing nothing, and `fit-window`
refused by name. A `msg --json subscribe` client joined before the two
`home-toggle` flights and received 46 State lines in the 1.6 seconds they and
their polling took, no two alike in a row, and 83 by the time the app exited
on SIGTERM with status 0 and the socket removed. So the flights of both
milestones land exactly on the one tick and the event stream keeps to a frame's
pace during them; a drift, an edge pan or a cursor pan was not produced, and
the stream's pace during one is the controller scenarios' and the shell's
once-a-frame throttle as read.

Not run at all, because each needs a real scroll, drag or pinch and none can
be injected: any drift after a flick or a drag, the pan under a dragged window,
cursor edge pan actually panning, a wheel zoom through the new command or a
pinch through the gesture commands, any of the config speeds applied to a real gesture, the dropping of
macOS inertia events, the lift-after-rest rule against real event times, the
50 ms delay inside the app, and frames being scheduled for a drift. The same
holds for the rules that only a held button or a second device reaches: the
pointer not being reported under a held press, a scroll handed over to a
window with its end and inertia, a scroll under a held drag pan leaving the
launch to the release, and zoom input dropped during a window drag. Also not
run: ⌃⌥E as a hot key (`--windowed` registers none), more than one display and
so the wait at a shared edge, a bound source, and anything drawn. These paths
are compiled and reviewed only.

## Persistence and lifecycle

The default scene file is
`~/Library/Application Support/Infinify/scene.json`. `--state /absolute/file.json`
selects another file whose parent directory already exists. Saves use the Rust
controller's private temporary file, fsync, atomic rename, and directory sync.
Only world geometry, display UUID cameras, bookmarks, app/title metadata and
which placeholders are stand-ins (by logical id) are
persisted; PIDs, window IDs, process births, and captures are not saved. Bookmarks,
the stand-in list (`standins`, written only while there is one) and the pinned
windows (`pins`, written only while there is one: the display and the place on
it, by logical id) are additive
fields of the same file and the format version is unchanged: scene
files written by older builds still load, with no bookmarks, no stand-ins and no pins. Older builds reject
fields they do not know, so an older build cannot read a scene file that contains
any of them; keep a copy of a scene file before opening it with an older build.
A widget is not saved at all, and neither is a window's rule or an opacity set
over the socket
([Window rules](#window-rules-widgets-and-pinned-windows)).
A bookmark change or window move made over the IPC socket below is saved the same
way. What a restart brings back follows DriftWM's `[session]` settings, whose
defaults are both off. With `restore_camera = false` every display starts as a
new one does, its top-left corner on the world origin at zoom 1, instead of at
its saved camera (cameras are still written, and a display that reconnects
during a run keeps the camera it had). With
`restore_bookmarks = false` the bookmarks start from the config's seeds alone,
bookmarks set at runtime last until quit, and a save carries the file's earlier
bookmarks forward untouched; set it to `true` to have runtime bookmarks saved
and laid over the seeds at launch. On a config reload a bookmark the file adds
or changes is re-asserted, one it removes is dropped, and the others keep their
runtime value. Home and Fit return positions are per display, in memory only: not saved, and
dropped on reload and whenever a display change recreates
the panels. Reloaded windows are unbound placeholders: one slot for every window
that was on the canvas at the save. While the app manages windows, a running
window takes its slot back by bundle identifier and title, never by PID or
window number, and the slots left over are dropped after each discovery pass
unless `[session] restore_windows = true` keeps them as stand-ins; a slot
whose titled window still exists off screen is kept, and nothing is decided
while the config file is refused
([Managed windows](#managed-windows)). With `--manual` nothing is matched and
nothing is dropped: a selection in its chooser is required to rebind. Without
Screen Recording access nothing is matched or dropped either: a normal run
shows the permission window instead of the canvas, and a `--windowed` run
shows the placeholders with no way to rebind them. A failed load blocks
source selection and disables every save path, preserving the original bytes until
an explicit different state path or repaired file is provided. Display changes
recreate panels while retaining cameras by stable display UUID; a wake, an
unlock and a Space change only put the existing panels back in front
([Desktop mode](#desktop-mode)). Source lifecycle and normal bounds are read on the
main event loop, by the poll and, in a managed run with Accessibility access, when an event names the window
([Event-driven tracking](#event-driven-tracking)); ScreenCaptureKit buffers independently report pixel dimensions.

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
$APP msg screenshot all -o ~/canvas.png
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
environment variable, then the default. The app itself does not read
`INFINIFY_SOCKET` to choose where it serves; it sets the variable to the socket
it serves for every command it starts (`exec`, `spawn`, `autostart`), so `msg`
from one of them reaches this instance. The socket's parent directory must exist, be owned by you and
not be group- or world-writable, the socket is mode 0600, and a peer with another
user ID is hung up on. A request is one line of at most 64 KiB (a longer one is
hung up on without a reply), at most 16 connections are served at once, and one
that completes no request for 30 seconds is closed, unless it has subscribed
(see [Event stream](#event-stream)). A stale socket file is removed
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
the centre of the view (the output: the whole display, or the whole window with `--windowed`), a window position the
centre of its frame in whole points, and a bookmark the point under the centre of
the view's usable area. The app registers no usable area
([The usable area](#the-usable-area)), so that is the whole
view and a bookmark set at a view equals its camera position. The controller's own
world is top-left, Y-down, and the controller converts. A window is selected by
`--id N`, the Infinify window id that `state` prints, or by a case-insensitive
part of its bundle identifier, where a window with a bound source wins over a
detached placeholder. Requests act on the active output: the one under the
pointer, else the one of the panel under the pointer, else the first. Before the
canvas first opens there is none: `camera`, `zoom`, setting `focus` and the view,
window and bookmark actions (`pan-viewport`, `home-toggle`, the zoom actions,
`center-window`, `center-nearest`, `cycle-windows`, `focus-center`,
`go-to-bookmark`, `set-bookmark`) answer `no active output`, and everything else
answers as it always does: `state`, `bookmark`, `move`, `debug-counters`, reading
`focus` or `resize`, `action quit`, and the unknown and not-implemented replies.
After a failed scene load every request answers the load error (`the
canvas is closed` was the answer after Return to desktop, which a normal run
no longer has), and while an
experimental native resize is unresolved `a native resize is pending`. That
last refusal is for a resize the pointer began and for any resize left
uncertain; while the size a [sizing action](#window-sizing-actions) asked for
is on its way, requests are answered as usual.

| Command | What it does now |
| --- | --- |
| `state` | Camera, zoom, the keyboard layout (the selected input source's name and short code), windows (id, bundle id as `app_id`, title, centre position, size, `is_widget`, `suspended` for a detached placeholder, and `mode`: `Normal`, or `Fit` or `Fill` while a [fit or fill](#window-sizing-actions) can still be undone; the readable form prints neither of those two, `--json` both), `pinned` (each screen-pinned window with its display and its `position` and `size` in `pinned_to_screen` rule coordinates; such a window is not under `windows` and has no `mode`), `fullscreen` (each [fullscreen](#fullscreen) window with its display; such a window is not under `windows` either; always empty in a default launch), outputs (stable id as `name`, `active`) and the active bookmark. The layer lists are always empty. |
| `subscribe` | Keep the connection and print the state now and again after every change, until the app exits. See [Event stream](#event-stream). |
| `layout [--short]` | The selected keyboard input source: its name, or with `--short` its first language code. Empty until the app has reported one, which it does at launch. |
| `camera [X Y]` | Read the view centre, or fly the camera there at the current zoom. A centre whose Y is 0 reads `-0` (`1950 -0`), as upstream's own client prints it: its Y-up conversion negates the zero, and nothing here rewrites that. |
| `zoom [LEVEL]` | Read the zoom, or animate to a level about the view centre. The level is clamped to the range the zoom shortcuts use and the reply is the level applied. |
| `focus [APP_ID] [--id N]` | Read the focused window. Setting makes a window the logical focus and, unless it is already wholly in view, flies the camera to it as upstream does: at 1:1 for a window with a bound source (at the current zoom with `[zoom] reset_on_activation = false`), at the current zoom for a detached placeholder. A pinned window is focused and raised with no flight; a widget, which only `--id` reaches, answers `window #N is a widget and cannot be focused`. For a window with a bound source the app also performs the controller's focus request on the native window when native focus is allowed (see [Window navigation and native focus](#window-navigation-and-native-focus)); that has not been run. |
| `move [X Y] [--id N]` | Read a window's centre, or move the logical window there (whole points). The native window is not touched. A move is refused while a gesture is active, when it would put the frame outside the 32-bit integer range every other request reads positions in, and for a pinned window (`this window has no canvas position to move: …`); a pinned window reads as the canvas point its pin shows. It is the one way to move a widget. |
| `resize [WIDTH HEIGHT] [--id N]` | Read the size, or set one; a pinned window and a widget answer upstream's `this window has no canvas size to set: …`. Setting one asks the native window for that size, keeps the window's centre where it is, raises the window over the other canvas windows without focusing it, as upstream's does, and answers with the size asked for, not the size the window ends up with; a detached placeholder is refused. While another window's size request is still unanswered it answers `a native resize of window N is still pending`. See [Window sizing actions](#window-sizing-actions). |
| `pin [on\|off] [--id N]` | Read whether a window is pinned to the screen, or pin or unpin it without moving it on screen. A live window only: a placeholder answers `stand-ins can't be pinned`. |
| `opacity [VALUE] [--id N]` | Read the opacity a window is drawn at, or set it (0 to 1; outside that is refused, not clamped) until the window is gone. A live window only. |
| `action SPEC...` | Run an upstream action string, below. |
| `bookmark [NAME] [X Y] [--delete]` | List bookmarks, get or set one, or delete it. |
| `close [APP_ID] [--id N]` | A window with a bound source: ask its application to close it (its close button, through Accessibility); it leaves no stand-in. A placeholder: dismiss it. |
| `suspend [APP_ID] [--id N]` | A window with a bound source: focus it, close it the same way and leave a stand-in. A placeholder: `window is already suspended`. |
| `relaunch [APP_ID] [--id N]` | A placeholder: open its application by bundle identifier; the next window of that application takes the slot. Answers `ok` once the request is made, also for an application that is not installed (status line and stderr then say so). |
| `debug-counters` | A small map of controller collection sizes; the keys are Infinify's own and not stable. |

`screenshot [--scale S] [-o PATH] [window [APP_ID] [--id N] | all | region X Y W H [--from-screen]]`
writes a canvas PNG; [Rendering](#rendering) has what it draws and where it
differs from upstream. Every request of upstream's protocol is answered: none
replies `<name> is not implemented on macOS yet` any more. `close`, `suspend`
and `relaunch` with no selector act on the focused window;
[Managed windows](#managed-windows) has their rules and limits.

`action` parses the full upstream action grammar with upstream's spelling: it
is the grammar the config file's bindings use. These run:
`pan-viewport <direction>`, `home-toggle`, `zoom-in`, `zoom-out`, `zoom-reset`,
`zoom-to-fit`, `zoom-to-fit-snapped`, `center-window`, `center-nearest <direction>`,
`cycle-windows forward|backward`, `focus-center`, `go-to-bookmark NAME`,
`set-bookmark NAME`, `move-to-bookmark NAME`, `toggle-pin-to-screen`,
`nudge-window <direction>`, `close-window`,
`suspend-window`, `send-to-output <direction>`,
`send-cursor-to-output <direction>`, `switch-layout next|prev|INDEX`,
`toggle-cursor-pan`, `set-trackpad on|off|toggle`, `exec COMMAND`,
`spawn COMMAND`, `exec-terminal`, `exec-launcher`, `reload-config` and `quit`.
`fit-window`, `fit-window-snapped`, `fill-window`, `grow-window <direction>`,
`shrink-window <direction>` and `toggle-fullscreen` run too
([Window sizing actions](#window-sizing-actions), [Fullscreen](#fullscreen)). Over the socket `cycle-windows` is always one
committed step, where upstream keeps the cycle open if a modifier happens to be
down, and `focus-center` uses the real pointer's position at that moment.
Every action but `cycle-windows` first ends a cycle in progress, and every
action stops the drift of the display it runs on, as upstream's does. `send-cursor-to-output` moves the real pointer and `switch-layout`
changes the selected input source, for whoever sends them. `close-window` and
`suspend-window` press the focused window's own close button.
`toggle-cursor-pan` and `set-trackpad` answer Ok and nothing else, as upstream's
do: the socket has no request that reads either state back. `exec` and `spawn`
make the app run
the command through `/bin/sh -c`, so the socket lets any process of yours that
can write to it run a command, as upstream's does. Every other upstream action
parses and answers `action not implemented on
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
see it land. A pointer press on the canvas, a scroll that pans it, or a bound
trackpad swipe or pinch stops a scripted flight where it is, like any other,
and a wheel zoom replaces it with its own. A client must wait for its reply: a
connection whose peer has already closed when the server accepts it is dropped
unread, where upstream would still run the request.

### Event stream

`Infinify msg subscribe` is `driftwm msg subscribe`. The connection stays open:
after the `{"Ok":"Ok"}` ack the app sends the whole state as one `{"State":{…}}`
line, the same payload `state` answers, and another such line whenever that
state changes: a camera or zoom move (one line per frame while a flight
animates, at most 60 a second, as upstream sends one per rendered frame), a
window added, moved, focused or removed, a bookmark becoming or ceasing to be
the active one, another keyboard layout. Nothing is sent while
nothing changes, and a state that serializes to the same bytes as the last one
sent is never repeated. `msg subscribe` prints upstream's readable state block
and a blank line for every event; `msg --json subscribe` prints each event line
as it arrived, members in upstream's order. The client exits 0 when the app
quits and the stream ends.

- At most 8 connections subscribe at once, out of the 16 the server holds. One
  more is answered `{"Err":"cannot subscribe: 8 subscribers are already
  connected"}`; upstream has no limit.
- A subscriber is never closed for being quiet. The app never waits on one: a
  subscriber that reads slowly is owed at most the unwritten rest of one event
  and the newest event behind it (older ones waiting there are superseded, since
  each is the whole state), as upstream. One that takes no byte of an owed event
  for 30 seconds is hung up on, where upstream keeps it. One that closes its end
  is dropped.
- A subscribed connection may go on sending requests. Each reply is a whole line
  of its own, written after any half-sent event has been finished. A second
  `subscribe` on it is answered with the ack and the current state again.
- The state is looked at after each redraw and each layout report, which covers
  every request, gesture and animation frame. The idle poll redraws as well,
  every 80 ms, so a change nothing else announces is still found: with several
  displays, the pointer moving to another one changes which output is `active`,
  and that is reported by itself within one poll.
- Before the canvas first opens (the permission window is up, or the chooser
  of a `--manual` run) a `subscribe` is accepted and its first line has no
  active output.

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
connection, line-length and idle limits against the app. `subscribe`, `layout`,
the subscriber limit and the display and layout actions were observed in two
later launches the same day, listed under
[What has been run](#what-has-been-run) with what those left unrun.

## Nested development window

`--windowed [WIDTHxHEIGHT]` (default 1200x800) is the macOS analogue of upstream's
nested winit backend. Instead of one whole-display floating panel per display it
opens the canvas immediately in one ordinary-level, non-activating panel with a
single output whose stable id is `windowed` and whose rectangle is the whole
panel: there is no strip, toolbar or status line. No global hot keys are
registered, so use the pointer and `Infinify msg`; the permission window is
never shown, and the chooser only with `--manual`, above the canvas. With
Screen Recording access it
manages windows like a normal run unless `--manual` is given; without, the
canvas still opens and says on stderr that it manages nothing
([Managed windows](#managed-windows)), unless `--only-pid` names the processes
whose windows it is to manage, which it then does with or without that access;
`--debug-pointer` beside it serves the `DebugPointer` request a test presses
with ([Managing only named processes](#managing-only-named-processes)). It is rejected in `--source`,
`--demo`, `--demo-probe`, `--demo-probe-guard` and owned-resize modes. It saves to
the default scene file, takes the default socket and reads the default config
file unless `--state`, `--socket` and `--config` say otherwise, so give a
development window its own when you also use Infinify normally. Pointer
bindings and settings from the config apply; key bindings are read but not
registered, and tap bindings are read but not watched.
`autostart` commands run, as they do under upstream's nested
backend, and hot corners bound for `windowed` or `*` are the corners of this
window while it is the window under the pointer. A size must be at least 960x480 (the
least it was when the window carried a toolbar) and at most 16384 in each direction, or the app exits 64; the
panel is then clamped to the main display's visible area and centred on it. It is
a borderless panel like the whole-display ones: it cannot be dragged, it has no
button, it closes only when the app quits (`Infinify msg action quit`, or
Control-C in its terminal), and a display change rebuilds it. Window
navigation and native focus run here as in any normal run; with no hot keys,
cycling is `msg action cycle-windows …`, one
committed step each.

Launched on 2026-10-09 as `--windowed 1100x700` with `--state`, `--config` and
`--socket`: `msg state` reported one output named `windowed` of 1100x636 (the
panel less its 64-point toolbar strip), and its camera was saved under that
name. The next launch, with no config file, did not restore it
(`session.restore_camera` is off by default) and started at a new output's
pose. The panel itself, its window level, the toolbar and the absence
of global hot keys were not inspected.

Launched again on 2026-10-10, in desktop mode, the same way: `msg state`
reported the output `windowed` as 1100x700 with its view centre at `550 -350`,
and a viewport screenshot was 1100 x 700 pixels of canvas with no strip
([What was run for desktop mode](#what-was-run-for-desktop-mode)). The panel on
screen was again not inspected.

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

Native AX layout resizing is implemented through guarded transactions rather
than simulated world-geometry changes. Native replicas now have separate
parented popup/sheet streams and implicit mouse capture across viewport bounds;
these source paths remain unverified with ordinary applications. Native
cross-application drag-and-drop, pointer lock/confinement, display-boundary
clipping and arbitrary family stacking remain incomplete. Pointer motion with no button down is forwarded to the
application under it, but has never been delivered to a real one, and the
cursor stays the canvas's own whatever that application would show. Right and middle clicks are forwarded through the
per-window route but have never been delivered to a real application. Ordinary selected app activation
works with the tested native window in the fixture modes; a normal run's click
now focuses through the focus driver instead, which has not been exercised, and
choosing among multiple native windows of one application and app-specific
focus rules needs broader validation.
A held pointer drag stays with its original native recipient beyond its tile.
Loss of ownership or current presentation cancels that capture; a copied release
is posted only while the same binding and native identity remain valid. This
implementation has not been exercised with physical cross-display input.
Desktop mode itself, the whole-display panels on every Space, the permission
window, the login item and what happens across sleep, lock and a display
change, has not been run on a display at all: [Desktop mode](#desktop-mode)
lists its own limits and what was run.
Minimized/hidden/Space transitions, display hotplug, IME composition, the
registered exit hotkey and the view-action and bookmark shortcuts require manual
validation on the intended workstation. The view actions, bookmarks and IPC
requests have exported-C-ABI/JSON controller test coverage, and scripted `msg`
sessions against a running `--windowed` app (see Scripting above) that left no
saved evidence. Their rendered animation, global-shortcut
delivery and stderr notes have not been verified on a live run, and neither
has IPC with bound sources or more than one display. The view actions end a fullscreen
first and Home has upstream's fullscreen-return leg, without its pointer
warp ([Fullscreen](#fullscreen)). Configuration covers key bindings, mouse bindings and the
settings listed under [Configuration](#configuration); hot key registration,
key repeat and every pointer binding are compiled and reviewed but have not
been exercised in a running app, and neither has a non-US keyboard layout.
Drift after a pan, the pan under a dragged window, cursor edge pan and the
config's pointer pan and zoom speeds ([Camera motion](#camera-motion)) have
controller test coverage and scripted `msg` sessions that could only reach
the toggle, a reload of their settings and the flights around them: no real
scroll, drag, swipe or pinch has been made against them, so how any of it moves
or feels under a hand is unverified, and that section lists where it knowingly
differs from DriftWM.
Media keys, touch-screen
gestures (`[touch.*]`), and every setting whose feature is absent are read and unused.
[Tap bindings](#tap-bindings) are built into the app and have run in it only
where a windowed launch reaches them, which is the controller's tap table at a
config load; the shell's tracker met the controller once more, in a throwaway
program with events built in memory. No chord has been pressed against it
([what was run](#what-has-been-run-for-tap-bindings)).
Whether macOS sends modifier changes to an app without Accessibility is not
known here; if it does not, a tap fires only while Infinify is the active
application. No [usable area](#the-usable-area) is sent, by the owner's
decision: nothing is reserved for the menu bar and the Dock.
Trackpad gestures have not been exercised on a trackpad: no physical gesture
has been performed. The controller's dispatch has exported-C-ABI/JSON coverage
with synthetic event streams, and the recogniser has been fed scripted touch
sequences in throwaway command-line programs (swipes, pinches, holds, taps,
finger-count changes and cancellations), once with its events passed on to the
real controller library; none of that left saved evidence, and the app's own
touch, timer and magnify glue has only been compiled (see
[Trackpad gestures](#trackpad-gestures)). Whether macOS delivers three- and
four-finger touches to the non-activating canvas panel, how the recogniser's
thresholds feel under a hand, and what macOS does with the same fingers at the
same time are all unverified, as is the two-finger pinch now that it goes
through the gesture table. macOS's own three- and four-finger gestures must be
turned off in System Settings by the user for the canvas to receive those
finger counts cleanly; Infinify changes no setting. Six of upstream's default
gesture bindings name `fit-window`, `fit-window-snapped` and
`toggle-fullscreen`, which run since 2026-10-11
([Window sizing actions](#window-sizing-actions)); its two resize gestures are claimed and do nothing, and an unbound gesture
is not forwarded to the application under it. The gestures that reach window
navigation (the four-finger swipe and hold, and any `cycle-windows` a config
binds) have run only as synthetic event streams against the controller.
Three of upstream's default key bindings and three of its default mouse
bindings (window actions: `toggle-fullscreen`, `fit-window` and
`fit-window-snapped`) do not run in a default launch, and its two resize
bindings need the experimental flag. That flag also turns on all three of
those keys and mouse bindings, with the other sizing actions; none of them
has resized a real window yet, see
[Window sizing actions](#window-sizing-actions) and
[Fullscreen](#fullscreen). Window
navigation and native focus have their own list of limits under
[Window navigation and native focus](#window-navigation-and-native-focus):
above all, native focus has never been exercised live, and a click reaches
the application before its window has native focus. Upstream's lock binding
puts the displays to sleep with `pmset`, which locks the session only as far
as the Lock Screen setting does; that command has not been run from the app.
With the default bindings a detached placeholder
cannot be dismissed with the pointer alone: a click focuses it, and
`close-window` (⌃⌥Q, or `msg`) then dismisses it.
Hot corners are watched by polling the pointer (every 80 ms, 60 times a second
while a flight, a drift or an edge pan runs), so a pointer that crosses a corner without resting there can
be missed, and none has been fired on a live run, so the `--windowed` rule that
a covered window's corners do not fire is unrun as well. `send-to-output` and
`send-cursor-to-output` have run live only with a single display, where they do
nothing: the window move to another display and the pointer warp are unrun.
`switch-layout` has run only on a machine with one enabled input source, where
it selects nothing; selecting an input method (as opposed to a plain keyboard
layout) from this accessory app is untried. The event stream reporting the
output under the pointer becoming active, within one idle poll, is unrun: it
needs a second display.
Window rules, widgets and screen-pinned windows have controller test coverage
and scripted `msg` sessions on placeholders; no rule has matched a real
window, no live window has been pinned in the app, and the widget and pinned
layers and a window's opacity have been drawn only offscreen, by a throwaway
tool that read frames back from the shell's renderer, never seen in the app's
own panel
([Window rules](#window-rules-widgets-and-pinned-windows) lists their limits).
The pass rules (`pass_keys`, `pass_mouse`), the wheel-notch bindings and the
drag of a pinned window, by the move binding and by the move gesture, have
controller test coverage only: no key was pressed, no hot key was seen being
unregistered, no real window received a passed key, press or scroll, no wheel
was turned and no pointer or swipe dragged a pinned window. A pinned window
is still not resized
([Passing keys and presses](#passing-keys-and-presses-to-an-application)
lists the limits).
The IPC surface is a subset of DriftWM's. Its six sizing actions (`grow-window`, `shrink-window`,
`toggle-fullscreen`, `fit-window`, `fit-window-snapped`, `fill-window`) and
the `resize` write run in every normal run since 2026-10-11. An IPC
focus is logical focus and camera navigation, plus a native focus request for a
window with a bound source that no run has yet performed, and
an IPC move is a logical world move that never moves the native window. Nested
`--windowed` mode registers no global shortcuts and has one output.
The compositor that now draws the canvas has been seen only through
`msg screenshot`, with stand-ins: the picture in the app's own panels, a
captured window drawn through it and its colour, and the outline of a second
display are compiled and read only. Blur, the open and close animations, the
stand-in fades and the error bar are drawn by that compositor and were seen
only in offscreen renders with synthetic pictures, never in a panel and never
with a captured window; move and resize animations are not drawn.
[Rendering](#rendering) has the list.
Cluster behavior uses the controller contract; fixture evidence currently has a
single source. Production chooser/managing of existing user windows has not been
run during development: automatic adoption, placement of a real window,
capture on demand, the close button press and relaunch are compiled and read
only, and [Managed windows](#managed-windows) lists their known limits. Ad-hoc signing is local development packaging, not a
notarized distribution build. Private SkyLight input symbols can change with OS
updates; unavailable symbols leave live viewing functional and input disabled.

## Window navigation and native focus

Every normal run (the default launch and `--state`, with or without
`--windowed`) navigates between windows as DriftWM does and tries to give the
real window native focus. The fixture and child modes (`--source`, `--demo`,
`--demo-probe`, `--demo-probe-guard`, the owned-resize modes) have none of it
and keep their fixed click activation. The controller's rules are in
[NAVIGATION.md](../../crates/desktop/NAVIGATION.md#window-navigation-actions)
and [FOCUS.md](../../crates/desktop/FOCUS.md); this section says what the shell
does with them.

**Native focus (raising the real window) has not been exercised live. It is
compiled, reviewed and covered by the headless coordinator regression only.**
No hot key, toolbar button, click or Option release has been exercised live
either;
[What has been run for navigation](#what-has-been-run-for-navigation) has the
exact boundary.

### Flags

- Native navigation is part of every normal launch. Its former experimental
  flag has been removed and is rejected as an unknown argument.
- `--no-native-focus` keeps focus logical: the shell activates no application
  and raises no window, for navigation or for a click, and installs no input
  observer. What a forwarded click makes the application do itself was not
  tried. Everything else in this section still happens. It is rejected (exit
  64) in the fixture and child modes and when given twice.
- `--no-hover-forwarding` keeps pointer motion from applications: with no
  button down, nothing is posted to the window under the pointer. Only that
  delivery is off. The motion is still reported to the controller, so
  `focus_follows_mouse` and pick mode work as without the flag, and clicks,
  drags and scrolls are forwarded as before. It is rejected (exit 64) in the
  fixture and child modes and when given twice. A launch with it started and
  answered `msg state`, and the flag given twice exited 64; that it keeps a
  motion from an application has not been seen, because no motion has been
  seen delivered without it either.

### Actions

| Control | Action | What it does |
| --- | --- | --- |
| ⌃⌥ arrow | `center-nearest <direction>` | Focuses the nearest window in a 90° cone and flies the camera to it at the current zoom. The search starts at the focused window while all of it is on the display, otherwise at the middle of the view. Detached placeholders are candidates, and so are `[navigation] anchors`: landing on an anchor flies the camera there and leaves no window focused. Nothing in the cone: nothing happens. |
| ⌃⌥C | `center-window` | Flies to the focused window, or with none to the window nearest the middle of the view, and focuses it, at 1:1. |
| ⌃⌥X | `focus-center` | The same for the topmost window under the pointer; over empty canvas, nothing. |
| ⌥Tab / ⌥⇧Tab | `cycle-windows forward` / `backward` | One step through the windows in most-recently-focused order, flown to at the current zoom. |

"Window" in all four means a window on the canvas: a
[widget or a screen-pinned window](#window-rules-widgets-and-pinned-windows)
is never picked, as upstream picks neither.

The chords are DriftWM's defaults under the default super chord; a config file
rebinds them like any other key. The toolbar buttons Center, Previous and Next
went with the toolbar on 2026-10-10. Hot keys
act on the display under the pointer, and
every one of them goes through the same `action` command as
`Infinify msg action`, with the pointer's position and whether a modifier is
physically down added by the shell. A [trackpad gesture](#trackpad-gestures)
bound to one of these actions runs it through the same dispatch: the pointer is
where the gesture began, and whether a modifier is down is read as the gesture
fires.

`center-window` is upstream's `RestoreFillElseReset`, and `focus-center` the
same: a window still filled by `fill-window` is flown to at the camera and
zoom its fill ran in, and any other at zoom 1. A pick-mode click does the same
for a filled window whose fill view is at or above `[zoom] interact_min`. A normal run supports
[window sizing actions](#window-sizing-actions), including fill; a stored fill
view is restored when present, otherwise the actions reset zoom to 1.

### Cycling and hold-to-commit

A `cycle-windows` hot key (or hot corner, or a trackpad gesture a config binds
to it) that fires while any of Control,
Option, Shift or Command is physically down opens a cycle that stays open: each further press
or swipe steps deeper into the order as it was when the cycle began. While it is open the
shell reads the session's modifier state 60 times a second
(`CGEventSourceFlagsState`, which needs no event tap and no Input Monitoring
grant), and at the first reading where the hold modifiers are no longer all
down it ends the cycle, which commits the selection to the front of the order.
The hold modifiers are upstream's `cycle_hold`: those of the
`cycle-windows forward` binding, Option by default. Upstream ends the cycle on
the key event of the release; sampling ends it up to 17 ms later.

A hot key step with no modifier down is committed at once, and so is every step
from `msg action cycle-windows …`,
which is never held. Any other action ends an open cycle first, committing it,
as upstream's does.

### Clicks

A press on a window that no mouse binding claims focuses that window first
(upstream's click-to-focus) and is then forwarded to the application as before.
"First" is the canvas's own focus: the window is the logical focus and raised
in the canvas before the press is forwarded. The native focus request is only
started by then. It runs on a worker, so the application receives the press
while that request is still in flight, not after its window has been made main
and raised. A detached placeholder is focused the same way and has nothing to
forward to.

With `[navigation] auto_navigate_on_click = true` a completed click on a window
that is not wholly in view also flies the camera to it at the current zoom, as
upstream does: when the button comes up, after the release has been forwarded,
and only if the pointer is within 5 points of where it went down, on the same
display, and the window still holds focus. The press itself never moves the
camera, so a drag that begins inside a clipped window reaches the application
as the drag it is. Upstream's extra wait after a title-bar click (so that a
double-click can still fit the window) does not exist here.

Any canvas press ends an open cycle the way letting go of its modifiers does: a
selection that has settled is committed, and a click on a window then puts that
window in front of it, as upstream does. A selection whose native focus is
still in flight is dropped with its request.

A press on empty canvas that is bound to pan and released within 5 points of
where it went down leaves no window focused; that is logical only, nothing is
asked of any application.

### Pointer motion, sloppy focus and pick mode

**No pointer has been moved over a running canvas with this code.** The
controller's rules are covered by its own tests, and the built app has been
launched and scripted through its socket, which has no pointer:
[What has been run for the pointer policy](#what-has-been-run-for-the-pointer-policy)
has the exact boundary. Everything the shell does with a pointer below is
compiled and reviewed only, and whether a canvas panel receives mouse-moved
events at all while Infinify is not the active application is part of what has
not been seen. The controller's rules are in
[POINTER.md](../../crates/desktop/POINTER.md).

A canvas panel is never key and its application is rarely active, so a normal
run takes pointer motion through a tracking area that is always active. The
newest motion is sent to the controller as `hover`, at most once a frame.
While the frame timer of [Camera motion](#camera-motion) runs, each of
its frames carries the motion that is waiting, ahead of cursor edge pan's
pointer report and the tick. That timer is also the one an animated
`[background]`, or a window that opens or leaves, keeps running
([Rendering](#rendering)); its frames then tick
nothing and still carry the waiting motion and the report. While no frame
timer runs, a timer of the hover's own
sends it, a sixtieth of a second after the last one at the earliest. Where the
pointer is has one reading for both, taken when the hover is sent and not from
the event: the pointer's position, and the output it is on, which is an output
only where a click at that point would land on that panel, so not under the
menu bar or the Dock, the chooser of a `--manual` run, a menu or, in a windowed
run, another application's window.

No hover is sent while the pointer or the pad is taken: a button is down, any
panel is handling a press, a drag or a pan, a
[trackpad gesture](#trackpad-gestures) is recognised or in progress (a swipe,
a pinch of two fingers or more, a hold), or a native resize has not drained. A
motion that arrives then is dropped, not kept for later. The controller
refuses the same on its own account, and one thing more that only it can time:
a scroll that has panned holds the pointer until its drift is launched, 50 ms
after its last pan. A hover never stops a flight or a drift. The fixture modes
send none. The shell then does what the reply says:

- **The motion is the application's** (`forward`): a mouse-moved event goes to
  the window under the pointer by the route a click takes, its source validated
  and the point mapped into the window the same way, whichever window holds the
  focus. It needs Accessibility access; without it nothing is posted and nothing
  is said. `--no-hover-forwarding` turns only this off. Nothing is sent when the
  pointer moves off a window, so an application may keep showing the pointer at
  the last point it was told. A tooltip or anything else the application opens
  appears at the real window, not on the canvas. Each delivered motion costs
  what a forwarded click costs (a snapshot, `hit`, `input` and the source's
  validation), at most 60 times a second while the pointer moves over a window,
  and once a frame while the frame timer runs (a flight, a coast, an
  animation): 120 times a second on a ProMotion display. Native family input
  keeps its own fresh identity and membership validation.
- **Sloppy focus** (`focus_follows_mouse = true`): the window under the pointer
  takes the focus without being raised and without the camera moving. Its native
  focus request is performed like a click's, and answered as logical without
  Accessibility or with `--no-native-focus`. Moving onto empty canvas keeps the
  focus; a click there still unfocuses. "Under the pointer" follows the
  layers of [Window rules](#window-rules-widgets-and-pinned-windows): a
  screen-pinned window takes the focus before whatever the canvas shows
  beneath it, and holds it outside the Option-Tab order like every focus of a
  pinned window; a widget is passed over, so moving onto one keeps the focus
  where it was, and under a pinned widget nothing takes it. The motion itself
  is delivered to a widget's or a pinned window's application like to any
  other. Windows that slide under a resting
  pointer during a flight are not focused until the pointer moves, as upstream;
  the same goes for a drift and for cursor edge pan, and none of the three is
  stopped by the focus a moving pointer then takes.
  A placeholder takes the focus too, as upstream's stand-in does. Nothing
  follows the pointer while a button is down, during a drag, a trackpad
  gesture or a native resize, for the 50 ms a scroll pan takes to launch its
  drift, or while an Option-Tab cycle is held open (upstream would end the
  cycle instead, and neither a trackpad gesture nor a scroll stops upstream's
  hover). The native request is the one a click makes, so the real
  window is activated and raised natively like a clicked one; only the
  canvas's own stacking is left alone. When the application then reports that
  window as key, the controller records it without raising it or moving the
  camera. That holds for 3 seconds after the hover at most: a report that
  comes later is the user's own activation, which raises the window and flies
  to it when it is clipped. Inside those 3 seconds, after a request that failed
  or that a press withdrew, a deliberate Command-Tab to the hovered window is
  still recorded in place, once.
- **Pick mode** (`[zoom] interact_min` above 0, the view zoomed out below it): a
  window or placeholder on the canvas is one target. A screen-pinned window is
  drawn at its own size whatever the zoom and is none: presses, scrolls and
  motion reach its application as above the threshold, also where it lies
  over a target, and ⌥-drag and the move swipe move it about its screen as
  above the threshold. A widget is none either, and is neither picked nor
  moved; its
  clicks and motion go on as above the threshold, as upstream's do: its
  pointer focus (`pointer_focus_under_pick`) withholds the pointer from an
  ordinary canvas window only and reaches a widget after that like at any
  zoom. Where a canvas window lies over a widget the press is that window's,
  a target, and the widget gets nothing there; a widget that is also pinned
  keeps its pointer under the same window
  ([POINTER.md](../../crates/desktop/POINTER.md#screen-pinned-windows-and-widgets)).
  A press on a target with any button focuses and
  raises it and is never forwarded, unless a binding whose modifiers are held
  claims the press (Option-drag still moves, Control-Option-drag still pans).
  It is a press like any other first: it ends an open cycle and a trackpad
  gesture in progress and stops every flight and drift. A
  left click released on the same display flies to the window at 1:1 (`pick`),
  which leaves pick mode (a window filled by `fill-window` goes back to the view it was filled in
  instead, when that view is itself above the threshold); dragged more than 5
  points it moves the window instead,
  from where the drag crossed that distance and without its cluster. That move
  is a window drag like any other: held at the display's edge it pans the
  canvas under the window ([Camera motion](#camera-motion)). A scroll
  with no binding over a target is looked up again as a scroll on empty canvas,
  so it pans or zooms, by the paths of any bound scroll: the pan is timed and
  drifts when the fingers lift, the wheel zoom is the animated one. A scroll
  that finds no binding there either is dropped, its end and macOS's inertia
  with it: nothing of it reaches the application. Trackpad gestures are not
  changed by pick mode, as upstream's are not: a three-finger tap and swipe
  over a target still focuses, raises and moves it, and a swipe or a pinch
  still pans or zooms. No motion is forwarded. The ⌃⌥-click that dismisses a
  placeholder while no binding claims it picks the placeholder instead in pick
  mode, as upstream's pick bypasses a stand-in's close button. Which binding
  claims a press or a scroll over a target is the controller's answer: the
  shell passes `pick` with each `mouse_binding` lookup. A target's
  `pass_mouse` rule counts for nothing there, as upstream: the bindings stay
  Infinify's; a pinned window's rule still gives its application the presses
  it lists ([Passing keys and presses](#passing-keys-and-presses-to-an-application)).
  A wheel notch bound to an action runs over a target as anywhere. The pick lands where
  `focus_placement` says. Pick mode takes precedence over the normal resize
  border. The
  zoom-out action, `msg zoom`, the wheel and the pinch all stop at half the
  zoom that fits every window, as upstream's do, so a low `interact_min` is
  never reached with few windows close together, as upstream notes.
- **`center-nearest` by pointer** (⌃⌥⌘ left drag by default): nothing happens at
  the press. The first drag event 16 points or more from it sends
  `pointer_nearest` once, and the rest of the drag is ignored, as upstream's
  grab fires once; the camera does not follow the pointer. The step is the
  key binding's action, run once with the pointer and the modifiers of that
  moment, so it stops the display's drift first as every action does; the
  press had already ended an open cycle and stopped every flight. A press released
  inside those 16 points does nothing. The drag pulls the canvas: dragging
  left goes to the nearest window on the right, dragging down to the one above
  (upstream's code does this, whatever its comment says), and a drag more than
  about 22° off an axis is a diagonal.

The source now supplies a pointing hand over pick targets on the canvas,
directional resize cursors and a closed hand during mouse pan/move grabs.
These shapes have not been exercised with a physical pointer. The captured
application's own cursor image remains unavailable over its replica.

### What has been run for the pointer policy

Historical evidence: invocations of `--experimental-native-resize` in this
subsection refer to the mode removed on 2026-10-12.

Automated, no window, no pointer and no native effect:
`crates/desktop/tests/pointer_flow.rs` drives `hover`, sloppy focus and its
echo, pick mode, `pick`, the `pick` flag of `mouse_binding` and
`pointer_nearest` through the exported C ABI with synthetic identities and
focus results ([POINTER.md](../../crates/desktop/POINTER.md#evidence-and-limits)
lists the scenarios), and with them what holds the pointer here besides a
window drag (a trackpad gesture, a drag pan, a scroll about to launch its
drift), what does not (a drift, a flight, cursor edge pan), and the swipe's
action ending a held cycle and stopping a drift once. The shell's sources
compile with the build script's flags (`-Wall -Wextra -Werror`) and link into
the app.

Live, on 2026-10-10 (ad-hoc signed build of this tree, macOS 27.2, Apple
Silicon): two launches as `--windowed 1100x700 --manual` with a private
`--state`, `--config` and `--socket`, on the seeded scene of three detached
placeholders used [for navigation](#what-has-been-run-for-navigation), driven
only through `Infinify msg`. Both were repeated the same day, with the same
output, on a build that has the 3 second bound on a hover's echo, the
pick-mode rule for the resize handles and the event-log trim under native
resize; none of those three can be reached through the socket. Nothing from the
launches is saved as evidence. Observed:

- a config of `focus_follows_mouse = true` and `[zoom] interact_min = 0.5`
  loaded with nothing on stderr, and `msg state` answered with the three
  windows and one output at zoom 1;
- `msg action zoom-out` eight times answered `ok` each time and `msg zoom` went
  0.909, 0.826, 0.751, 0.683, 0.621, 0.564, 0.513, 0.467: below the threshold,
  the output is in pick mode by the controller's rule. `msg state` showed that
  zoom and nothing else: neither pick mode nor `focus_follows_mouse` is
  readable through `msg`, whose replies are upstream's. `msg action zoom-reset`
  brought the zoom back to 1;
- the config rewritten with `focus_follows_mouse = false` and
  `msg action reload-config`: `ok`, nothing on stderr;
- the file rewritten with `interact_min = -1.0`, then `5.0`, each picked up by
  the file watcher within 0.3 s and reported on stderr in upstream's words:
  `config: zoom.interact_min -1 below minimum 0, using 0` and
  `config: zoom.interact_min 5 above maximum 1, using 1`; written back valid,
  nothing more was printed;
- a second launch with `--no-hover-forwarding` started, answered `msg state`
  and `msg zoom`, and the flag given twice exited 64 without opening anything;
- both launches exited 0 on SIGTERM with their socket removed.

Those launches were of the pointer policy built by itself, before
[camera motion](#camera-motion) and [trackpad gestures](#trackpad-gestures)
were under it. The build that has all three was launched twice more on
2026-10-10, the same way but without `--manual` (it reported on stderr that it
manages no window, having no Screen Recording access), for 9 seconds and for
1 second, and left no saved evidence either. Observed there, through
`Infinify msg` alone:

- the same config (`focus_follows_mouse = true`, `[zoom] interact_min = 0.5`)
  loaded with no config line on stderr, and `msg state` listed the three
  placeholders;
- `msg action "center-nearest right"` flew to the seeded window at `1950 0` and
  focused it, `pan-viewport right` moved the camera from 1950 to 2050,
  `zoom-to-fit` went to zoom 0.285 and a second one came back to 1;
- eight `zoom-out` actions gave the same eight zooms as above, ending at 0.467,
  and `zoom-reset` returned to 1;
- `toggle-cursor-pan` twice and `set-trackpad off` then `on` each answered
  `ok`;
- the reload with `focus_follows_mouse = false` answered `ok` with nothing on
  stderr, and `interact_min` written as `-1.0` and as `5.0` was reported by the
  file watcher with the same two lines as above;
- the second launch, with `--no-hover-forwarding`, answered `msg state`, and
  the flag given twice exited 64 with no socket made;
- both exited 0 on SIGTERM with their socket removed.

What the merge itself changed in the shell was not reached by any of that: the
hover going out with a frame of the frame timer instead of on its own timer,
the one reading of the pointer it shares with cursor edge pan's report, the
hover standing down for a trackpad gesture, the time sent with it, a scroll
over a pick target panning with drift, and the swipe's `held`. They are
compiled and read only, like the rest of this section.

The pointer policy was then joined to
[window rules, widgets and pinned windows](#window-rules-widgets-and-pinned-windows)
and to [rendering](#rendering), both of which were staged and not yet
committed at the time. What that join decided is in the rules above: a
pinned window first and a widget never for sloppy focus, neither a pick
target, the handles left off a display in pick mode, and the hover carried by
the one frame timer also while only an animated background keeps it running.
The build that has all of it passed `./scripts/build-app.sh` on 2026-10-10
(macOS 27.2, Apple Silicon), `pointer_flow` with three scenarios added for a
pinned window and a widget under the pointer, the scenarios of every other
controller module and the coordinator regression, and was launched twice
(`--windowed 1100x700`, a private scene of the same three detached
placeholders, config and socket, no Screen Recording access; 6 seconds and
under a second). Nothing from those launches is saved as evidence. Observed,
through `Infinify msg` alone:

- the config (`focus_follows_mouse = true`, `[zoom] interact_min = 0.5`)
  loaded with no config line on stderr, and `msg state` listed the three
  placeholders and one output at zoom 1;
- `msg action "center-nearest right"` ended at camera `1950 -0` with `#2` (the
  seeded "Browser") focused, `pan-viewport right` at `2050 -0`, `zoom-to-fit`
  at zoom 0.2848 and a second one back at 1;
- eight `zoom-out` actions gave the same eight zooms as above, ending at
  0.4665, below the threshold. `msg screenshot` there wrote a 2358×1363 PNG,
  which was looked at: the focused placeholder alone in view, drawn by the
  compositor as a stand-in with its application id and close cross, about 38%
  of the picture's width, on the dot grid. `zoom-reset` returned to 1;
- the file rewritten with `focus_follows_mouse = false` and
  `msg action reload-config`: `ok`, nothing on stderr;
- `msg screenshot window --id 2` wrote the 900×600 placeholder alone;
  `toggle-cursor-pan` twice answered `ok`; `msg pin --id 1` and
  `msg pin on --id 1` both answered `stand-ins can't be pinned`;
- the second launch, with `--no-hover-forwarding`, answered `msg state`,
  `msg zoom` and `msg focus`, and the flag given twice exited 64 with no
  socket made;
- both exited 0 on SIGTERM with their socket removed.

None of what the join changed was reached by that: the scene held stand-ins
only, which cannot be pinned and are no widgets, so no pinned window and no
widget was under anything; no launch had an animated background or
`--experimental-native-resize`, and a screenshot shows neither the panel nor
the handles. A pinned window or a widget under the pointer is covered by the
controller's scenarios alone, and the frame that serves a background, the
handles left off in pick mode and a placeholder's pick flag are compiled and
read only.

No `hover`, `pick` or `pointer_nearest` command was driven in the app, in any
of the six launches: only a
pointer sends them, the socket has none, and no pointer was moved or clicked
for these launches. Whether the pointer of the person at the machine crossed
the panel during those seconds is not known and nothing recorded it. So none
of the following was seen, in these launches or anywhere else: a mouse-moved
event arriving at a canvas panel; a `hover` sent, coalesced or skipped; a
motion delivered to an application or kept from one by
`--no-hover-forwarding`; focus following the pointer, its native request
performed or answered, or its echo recorded or expired; a pick-mode press
swallowed, dragged into a move or released into a pick; a press on a resize
handle in pick mode (no launch had `--experimental-native-resize`); a scroll
over a pick target; the ⌃⌥⌘ swipe; a window with a bound source, a pinned
window or a widget under any of them; anything drawn on the panel; more than
one display.

### What focusing does natively

Each of the above makes the window the logical focus and raises it in the
canvas at once. For a window with a bound source the controller also returns a
focus request, and the shell performs it when native focus is allowed: on a
serial worker the focus driver validates the window's identity (PID, process
birth, window id, current owner and unchanged bounds) against the binding the
controller named, activates its application, sets the window main and focused
through Accessibility, raises it, and reads back that exactly that window now
holds focus, all inside 1.5 seconds. Only that window is acted on; no other
application's window is raised, moved or resized. The result goes back to the
controller, and only a confirmed focus enters the most-recently-focused order;
a request the driver tried and failed cancels an open cycle.
A newer request, a canvas press, a scroll that pans or zooms the canvas, the
begin of a trackpad swipe, pinch or hold over a display, opening the chooser,
adding, rebinding or losing a source, Return to
desktop and a display change all withdraw a request that is still in flight.
Of these only the press also ends an open cycle whose selection has settled: a
scroll or a trackpad gesture leaves it open until the hold modifiers are let
go, as upstream does, so a swipe bound to `cycle-windows` can step it. Camera
flights and drift are another matter: a press stops every display's, and a pan,
a wheel zoom and a bound swipe or pinch stop or replace only their own
display's, in the controller ([Camera motion](#camera-motion)).

Native focus is allowed when Infinify has Accessibility access and
`--no-native-focus` was not given. Access is re-read at every read of native
focus, at least once a second, so a grant
made while the app runs should take effect without a restart (not tried).
Without it focus stays logical, all of the navigation above still works,
cycling included, and the status line and stderr say so once:
`Native window focus needs Accessibility access: focus is logical only;
navigation still works.`

When native focus is not allowed the focus driver is never asked. The shell
answers each of the controller's focus requests at once as logical
(`focus_logical`), which claims nothing about any native window: the window
enters the most-recently-focused order as it would under upstream, where
focusing is all there is, and a held cycle steps on and commits on release.
What is lost is only the native half: the real window is not activated or
raised, so keys still go to whichever application was frontmost.

Native focus does not depend on Input Monitoring. If that access has already
been granted (the app never asks for it), a listen-only observer of mouse
presses and scrolls is also installed: a press or scroll outside the canvas
panels while a focus request is in flight withdraws that request. It observes
no keys and nothing else depends on it.

### Native focus is followed

When Accessibility access exists, the shell reads which window the frontmost
application has focused. In a managed run it reads when an application is
activated or changes its focused window
([Event-driven tracking](#event-driven-tracking)), at the first poll after a
window is adopted (its focus event may have come before the canvas had the
window), and once a second besides, so Command-Tab is followed as it happens. Twice a second, as before, in a run
that manages no windows (`--manual`, no Screen Recording access) and while
some application is not observed in full. What a read finds is compared with
what the canvas already has, so reading more often reports nothing twice. If
that is a window on the canvas and
the canvas did not ask for it (Command-Tab, the Dock, an application raising
its own window), the canvas follows as upstream follows an activation request:
the window becomes the logical focus, is raised and moves to the front of the
most-recently-focused order; if it is clipped on the display that shows its
centre, that display's camera flies to it, at 1:1 unless `[zoom]
reset_on_activation = false`; a window already wholly visible there is left
where it is. If the frontmost window is not on the canvas, the canvas forgets
that a canvas window held native focus and drops an open cycle without
committing it; logical focus stays.

### Limits the owner will notice

- **What enters the cycle order.** With native focus allowed, the
  most-recently-focused order holds only windows whose native focus the driver
  confirmed or the shell observed: a window whose focus request fails, or is
  overtaken by the next one before it is confirmed, is not in it, where
  upstream would have put it there. Without native focus (no Accessibility
  access, or `--no-native-focus`) every window you focus on the canvas enters
  it. A detached placeholder is never in the order (upstream's stand-ins are
  not either), so a canvas of placeholders alone cannot be cycled. The same
  order decides who takes the focus when a window closes
  ([Managed windows](#managed-windows)).
- **A click reaches the application before its window has native focus.** The
  press is forwarded while the native focus request is still in flight. What an
  application does with a press that arrives while it is not yet active (take
  it as an activation click, for instance) has not been tried.
- Option-Tab and Option-Shift-Tab are global hot keys while a canvas panel is
  open: other applications do not receive them.
- A canvas press ends an open cycle at the press, on empty canvas too, where
  upstream ends it when another window takes focus or the modifiers are let go.
- Every click on a window with a bound source, including one inside the window
  that already has focus, runs the whole native focus sequence again.
- `auto_navigate_on_click` has no double-click deferral and no title-bar case:
  every completed click on a clipped window pans at once.
- A press bound to move or resize a window raises and focuses it first, as
  upstream's does; one whose move or resize the controller refuses focuses
  nothing, where upstream's press has by then raised and focused the window.
  No such press has been made with a real pointer: this is compiled and read
  only.
- Hover, `focus_follows_mouse`, pick mode and the pointer form of
  `center-nearest` (upstream's ⌃⌥⌘-drag swipe; its trackpad form is the
  four-finger swipe) have never been tried with a real pointer, see
  [Pointer motion, sloppy focus and pick mode](#pointer-motion-sloppy-focus-and-pick-mode).
  The source now provides the canvas's pick, resize and mouse-grab cursors;
  the captured application's own cursor is still unavailable over a replica.
  Other differences remain:
  an application is not told when the pointer leaves its window; sloppy focus
  raises the real window natively although the canvas does not restack; a
  window enters the Option-Tab order when its focus request is answered, not
  at the hover; a held Option-Tab cycle stops sloppy focus instead of being
  ended by it; a trackpad gesture in progress, and a scroll for the 50 ms
  before its drift launches, keep focus and motion from following the pointer,
  where upstream's hover runs on; a pick lands at 1:1, but for a filled window, which returns to its fill
  view if that view is at or above the threshold; pick mode is per display.
- Modal windows do not exist here, so none of upstream's special cases for
  them apply. The filled window's view restore above is
  brought over for `center-window`, `focus-center` and a pick, and a
  fullscreen window is focused on its own display, never flown to and no
  pick target ([Fullscreen](#fullscreen)). A widget or a screen-pinned window
  is focused where it is and never flown to, by a completed click or by a
  followed native focus; a hover focuses a pinned window where it is and
  passes over a widget, and neither is a pick target
  ([Window rules](#window-rules-widgets-and-pinned-windows)).
- Following native focus moves the camera by itself when an application on the
  canvas takes focus while its window is clipped.
- If the controller refuses to follow a native focus change (a drag or resize
  is in progress), the focus is still recorded, the camera stays, and the
  refusal text shows in the status line.

### What has been run for navigation

Automated, no window and no native effect:
`crates/desktop/tests/navigation_actions_flow.rs` and the other controller
scenarios drive the actions, `activate`, `clear_focus` and the cycle rules
through the exported C ABI with synthetic identities and focus results, and
`./tests/e2e/desktop-navigation.sh` runs the real Objective-C coordinator
against the real Rust library with an injected focus driver, clock and
scheduler. The regression covers exact identities and binding generations,
held, reverse and release-pending cycles, the hold opened and ended by injected
modifier readings, a canvas press on a held cycle with its selection settled and
still in flight, unrelated input with and without a request in flight, a focus
request carried inside an action reply's `effects`, a request the controller
dropped, logical-only focus never reaching the driver while it enters the order
and a held cycle steps and commits on it, authorization, failure
and deadline, supersession, rejected commands, native focus followed through
`activate`, focus lost, two-output camera flights and their saved poses, and
teardown. It starts no NSApplication, window, hot key or event tap and focuses
nothing.

Live, on 2026-10-09 (ad-hoc signed build of this tree, macOS 27.2, Apple
Silicon): four launches as `--windowed 1100x700` with a private `--state`,
`--config` and `--socket`, on a seeded scene of three detached placeholders
(Notes 640x420 centred on 520,-360; Browser 900x600 on 1950,0; Terminal 560x380
on -620,-890, in `msg` coordinates), driven only through `Infinify msg` and
read back with `msg camera`, `msg zoom`, `msg focus` and `msg state` once each
flight had settled. Nothing from them is saved as evidence. Observed:

- `center-nearest right` with nothing focused, from the launch view (camera
  550 -318): focus on Browser, camera 1950 0;
- from there `left`: Notes, camera 520 -360; `down` and `up` from Notes with no
  anchors: nothing changed; `left`: Terminal, camera -620 -890; `up-right` from
  Terminal: Notes;
- `[navigation] anchors = [[520.0, -3000.0]]` written to the config file
  while running: `down` from Notes then landed on 520 -3000 with no window
  focused, `up` from there chose Terminal over Notes, as the scoring rule says
  (2305 against 2430), and `down` from Terminal went back to the anchor;
- with nothing focused and the view moved to 520 600, above Notes, `down`
  chose Notes; with Notes focused and the view moved to 520 -1500, so that
  Notes was off the display, `up` chose Notes, which only a search from the
  middle of the view finds;
- at zoom 0.5, `right` from Notes: Browser, zoom still 0.5;
- `center-window` with Terminal focused after `msg camera 2000 2000`: camera
  -620 -890, zoom 1; after `msg zoom 0.5` and `msg focus --id 2` (camera 1950 0,
  zoom still 0.5), `center-window` kept the camera and brought the zoom to 1;
  with focus cleared on the anchor at zoom 0.5, `center-window` chose
  Terminal, the window nearest the middle of the view, at zoom 1;
- `cycle-windows forward`, `forward`, `backward`: `ok` each time, and focus,
  camera and `msg state` were the same before and after, because no
  placeholder is ever in the order (the first limit above). `msg state` lists
  the focused window and then the stacking order, not the
  most-recently-focused order, so that order is not readable through `msg`;
- `center-nearest sideways` answered `unknown direction: sideways`, a bare
  `center-nearest` `center-nearest requires a direction`, a bare
  `cycle-windows` `cycle-windows requires forward or backward`, and
  `cycle-windows sideways` `cycle-windows: expected forward or backward, got
  'sideways'`, each with exit status 1;
- `focus-center` answered `ok` with the pointer wherever it happened to be and
  changed nothing; its effect was not established;
- a launch with `--experimental-native-navigation --no-native-focus` started,
  navigated and answered like the others;
- each launch exited 0 on SIGTERM with its socket removed, and the scene file
  read after the last held that run's focus, stacking order, camera and zoom.

No launch printed the missing-Accessibility note, so the session presumably
had Accessibility access and native focus was allowed in the three launches
without `--no-native-focus`; that was not checked separately. With no bound
source the controller produced no focus request, so neither the focus driver
nor the logical-only answer was reached, and no window on the canvas could be
found frontmost; nothing in the output shows any of those paths doing
anything.

On 2026-10-10 the build that adds [camera motion](#camera-motion) and
[trackpad gestures](#trackpad-gestures) to this was launched once in the same
way: `center-nearest right` and `left`, `center-window` and
`cycle-windows forward` answered and landed as above
([the run](#what-has-been-run-of-camera-motion)). A read-only check made in
that session reported Accessibility access and no Screen Recording access for
processes it starts, which fits the notes printed and not printed.

Not run at all: native focus of a real window by any route; a window with a
bound source; any hot key, Option-Tab and the release that commits it; the
toolbar's Center, Previous and Next; any click, click-to-focus, the reveal at
a completed click's release, a press that ends a cycle, and the empty-canvas
unfocus; a trackpad gesture that fires one of these actions, or a scroll or
gesture during a focus request or an open cycle; native focus being followed;
the observer withdrawing a request; a
cycle that changes the order in the running app, with native focus or on
logical focus alone; the status note for missing Accessibility;
`auto_navigate_on_click` and `reset_on_activation` in the app; anything drawn;
more than one display.

## Window sizing actions

DriftWM's sizing actions are controller policy here: which size, which place,
which camera and what a second press gives back are upstream's rules, set out
in the [sizing contract](../../crates/desktop/SIZES.md). One of them,
`zoom-to-fit-snapped`, moves a camera and nothing else, and runs in every
normal run. The others end by giving a real window a new size, and since
2026-10-11 they too run in every normal run, with no flag.

**How a size reaches a window, and what settles it.** The controller asks the
shell for one thing at a time: read the window, set its size, read it again.
The shell does that through Accessibility (the size attribute is the only
thing written; nothing sets a position) and reports what the window server
and Accessibility then say the window's size is. That size is the window's
size on the canvas, whatever was asked: a window that has a minimum, a maximum
or a resize increment ends at the size its application allowed, and the canvas
agrees with it. Nothing waits for a picture of the window. A request that the
application does not answer is ended by itself (the Accessibility calls give up
after 0.15 seconds each and 2 seconds in all, and three seconds after an effect
was handed out the shell answers for it), and the window is usable at the size
it has throughout: no tile goes blank and no click is refused for a size
request. This is the controller's
[readback mode](../../crates/desktop/NATIVE_RESIZE.md#readback-mode).

**What has been resized.** Disposable fixture windows of the test's own, and a
generic Electron window, in a windowed run scoped to them without Screen
Recording access: `tests/e2e/scoped-sizing.sh`,
[What has been run for sizing without the flag](#what-has-been-run-for-sizing-without-the-flag).
No application of the owner's has been resized by it, and no key chord has
been pressed by a test.

### When resize runs

| Launch | What runs |
| --- | --- |
| default | Everything in this section: `zoom-to-fit-snapped`, `fit-window`, `fit-window-snapped`, `fill-window`, `grow-window`, `shrink-window`, `msg resize WIDTH HEIGHT`, and a [window rule](#window-rules-widgets-and-pinned-windows)'s `size`, asked of a new window that matches it. Keys bound to those actions are registered where a run registers keys. A size is settled by reading the window back. |
| `--demo*` | As before: a demo and a probe are told nothing and answer `action not implemented on macOS yet: <name>`. |

All of them act on canvas windows. With a widget or a screen-pinned window
focused the five sizing actions and `zoom-to-fit-snapped` do nothing, as
upstream's do; `msg resize WIDTH HEIGHT` on one answers
`this window has no canvas size to set: it is pinned, fullscreen, a widget, or not on screen yet`
in either launch; and neither is in the way of a fill, pushed by
`fit-window-snapped` or framed by `zoom-to-fit-snapped`.

There is no other switch, no config key for it, and the flag is not the
default. The fixture modes (`--demo*`, `--owned-resize-*`) get none of it, with
or without the flag.

### What each one does

| Control | Action | Runs | What it does |
| --- | --- | --- | --- |
| ⌃⌥⇧W; ⌃⌥ with a four-finger pinch in | `zoom-to-fit-snapped` | always | Frames the focused window's snap cluster: the windows joined to it edge to edge at `[snap] gap`, placeholders included, with `[zoom] fit_padding` around them. A second press returns to the view left, as Fit does. With no window focused, nothing. |
| ⌃⌥M; ⌥ middle click on a window; ⌥ with a two-finger pinch on a window | `fit-window` | flag | Asks the focused window for the size of the display's view less `[snap] outer_gap` on every side, keeps its centre where it is, flies that display's camera to it at 1:1 and focuses it. A second press gives back the size it had before it was fitted or filled, around the centre of the frame the fit asked for, wherever the window has been moved by then; no camera moves. |
| ⌃⌥⇧M; ⌥⇧ middle click; ⌥⇧ with a two-finger pinch | `fit-window-snapped` | flag | The same, and the windows snapped to it are pushed outward by the distance each of its edges travels, then brought back by the second press. |
| none (upstream suggests `mod+g`) | `fill-window` | flag | Grows the focused window in place into the free space of the display that shows it: up to `outer_gap` from the edge of the view and `[snap] gap` from every other canvas window, pulling back an edge that sticks out. No camera moves. A second press puts it back where it was, at the size it had before it was filled or fitted. |
| none | `grow-window <direction>`, `shrink-window <direction>` | flag | Moves the named edge of the focused window outward, or inward, by `[navigation] resize_step` (20) points; the opposite edge stays where it is. A diagonal moves two edges. Held, the key repeats. |
| `Infinify msg resize WIDTH HEIGHT [--id N]` | IPC resize | flag | Asks one window for that size and keeps its centre. The reply echoes the size asked for. The window is raised over the other canvas windows, as upstream's `resize` raises a client, and is not given the focus. |

A config file binds any of them to a key, a mouse button, a trackpad gesture
or a hot corner in DriftWM's grammar, and all of those arrive through the same
action dispatch as `Infinify msg action`. None of them, `zoom-to-fit-snapped`
included, writes anything on the status line when it runs; a refusal is shown
there.

With the flag, by the code:

- The action's reply starts a size transaction on the window, the same one a
  handle drag runs: a read of the window's size, one Accessibility size change,
  a read of what the window then is. The canvas keeps the old frame until that
  answer arrives. The frame, the place, the neighbours' shift and the fit or
  fill mode are then written for the size the window **actually** took: a
  window that clamps the request, or refuses it, is committed at what it
  became. Only the size is ever asked of the native window; its position on
  the desktop is not touched.
- `fit-window` flies the camera and asks for native focus at once, before the
  window has answered. If the resize then fails, the camera has still gone to
  the window.
- A fitted window is measured by the frame the fit asked for, not by the size
  the window took. So a window that accepts less than the fit asked, or
  refuses it, still goes back to where it was at the second press, and the
  windows `fit-window-snapped` pushed come back with it.
- A fit or a fill measures its window by the size the window was last asked
  for, by a step, `msg resize`, a rule's `size`, a fit, a fill or the press
  that undoes one, and not by what the window took of it, as upstream
  measures a client by the size it last configured. A window stepped from 400
  to 430 wide that stopped at 410 has its next `fit-window` centred on the
  430-wide frame at its top-left, `fit-window-snapped` pushes the windows
  snapped to that frame, and `fill-window` grows from it. A window that was
  asked nothing is measured by the size it has, and a resize by handle makes
  it so again.
- The size a second press gives back is the one the window had before a fit or
  a fill last changed it. A fit pressed on a filled window, or a fill after a
  filled window was moved, still comes back to the size from before the fill.
  A resize by handle, by step or by `msg resize` starts that over.
- While a size is on its way, further actions and `msg` requests are answered.
  A held `grow-window` key keeps stepping: each repeat walks on from the size
  already asked for, and the window is asked for the latest one when it
  answers. Anything that cannot share the one transaction (a step on other
  edges, a fit, a fill, sizing another window) answers
  `a native resize of window N is still pending`. So does the controller for
  a drag of that window, which the shell does not send: the press is dropped,
  as the next item says. A step walked back to the size the window already has
  sends nothing, and ends fit and fill at once.
- A pointer press on the canvas, a scroll, a pinch and the start of a trackpad
  gesture are dropped until the size has settled, and no input is forwarded to
  an application meanwhile, pointer motion included, and sloppy focus stands
  still, as during a handle drag; unlike there, the press does not cancel it. Escape asks to cancel it, as it does a handle drag: a size not yet sent
  is dropped, one already sent is still read back and committed.
- A window whose size no longer matches what the canvas holds (it was resized
  in its own application during this run) fails the first read, and the status
  line says `Window not resized: baseline size differs from committed logical
  size`. A window the resize driver will not touch is left alone without a
  message, and later attempts on it answer `source resize unsupported`.
- On a detached placeholder `fit-window`, `fit-window-snapped` and
  `fill-window` do nothing and answer `ok`, as upstream's do for a stand-in;
  `grow-window` and `shrink-window` answer `<name> needs a live window: a
  stand-in has no native size to change`, and `msg resize W H` answers `this
  window has no native size to set: it is a stand-in or has no live window`.
  Upstream resizes the stand-in's own frame for those two; here nothing could
  deliver that size when the window comes back.
- During a pointer drag of a window every sizing action is refused (`a window
  is under an interactive move or resize`).
- `Infinify msg --json state` reports each window's `mode`: `Normal`, `Fit` or
  `Fill`. Moving a filled window (a drag, `nudge-window`, `msg move`,
  `send-to-output`) ends its fill, so the next `fill-window` fills again
  instead of restoring; a fitted window stays fitted when moved, as upstream's
  does. A resize by handle, by step or by `msg resize` ends both. Neither is
  saved: after a restart a fitted window is an ordinary window of that size.
- `center-window` and `focus-center` on a window still filled return to the
  camera and zoom the fill ran in, instead of 1:1, and so does a pick-mode
  click when that zoom is at or above `[zoom] interact_min`.
- A window pinned to the screen after it was fitted or filled keeps that mode,
  as upstream's does: nothing sizes it while it is pinned, `state` lists it
  under `pinned` without a mode, and once unpinned the second press still
  gives its size back. `send-to-output` ends the fill of a canvas window and
  leaves a pinned one's alone.
- A window rule's `size`: a window that appears by itself and matches such a
  rule is placed for the size the rule names, as upstream places it, a widget
  and a window the rule pins included: a `position` is the centre of that
  size, and the pin, the placement policy and the camera's flight to the new
  window take that frame. `position = [0, 0]` with `size = [800, 600]` puts
  the top-left at canvas (-400, -300) whatever size the window opened at.
  Until the window has answered it stands at its own size in the middle of
  that frame (a pinned one at its pin), and its attach reply starts the same
  size transaction for the rule's size. A window that takes the size lands on
  the frame to the pixel; one that takes another keeps the frame's top-left.
- There is one size transaction, so several such windows that appear together,
  at launch too, are asked one after another in the order they appeared. Each
  waits at its own size, `rule.not_applied` in the snapshot still naming
  `size` for it, and is asked in the reply to the result that ends the
  transaction before it, whoever began that one. A window that appeared during
  a drag is asked with the next new window or when the next transaction ends,
  not when the drag ends. One that closes, or whose application goes, while it
  waits is not asked, and neither is one that is sized meanwhile, by a sizing
  action, by `msg resize` or by a resize handle: DriftWM applies a rule's size
  once, as the window appears, and never over a size given since. While it
  waits it can be moved, dragged by a move and pinned like any window. A
  later window is placed off the frame a waiting or just-asked one is
  taking, so several of one rule that appear together cascade and none
  lands on another. A window that takes over a saved slot and a window
  attached from the chooser are never asked.

### What changes for someone who used the previous build

Historical evidence: invocations of `--experimental-native-resize` in this
subsection refer to the mode removed on 2026-10-12.

In a default launch:

- ⌃⌥⇧W is now a registered global hot key while a canvas panel is open
  (`zoom-to-fit-snapped`), where the chord used to stay with the applications.
  Unbind it in the config file (`"mod+shift+w" = "none"`) to give it back.
- Control-Option with a four-finger pinch in now frames the focused window's
  cluster, where it showed a not-implemented note.
- Since 2026-10-11 the five sizing actions and the `msg resize` write run, as
  below; a controller that is told nothing still answers byte for byte as
  before, which a controller test compares against the replies captured from
  the previous tree.

In every normal run:

- ⌃⌥M and ⌃⌥⇧M are registered global hot keys, and Option-middle-click or
  Option with a two-finger pinch on a window now asks that real window to
  change size.
- An action or a `msg` request that arrives while a sizing action's size is on
  its way reaches the controller, which answers it. For a resize the pointer
  began (the flag) they are still dropped, or answered `a native resize is
  pending`, and an action still cancels it, as before.
- A press, a scroll or a gesture on the canvas during a sizing action's
  transaction is handled as at any other time. Only under the flag is it
  dropped.
- A config whose window rule names a `size` now asks a matching new window to
  take that size; before, the size was only
  recorded. Under the flag such a window is first drawn, growing and fading in, when that
  request has been answered
  ([window animations](#blur-window-animations-and-the-error-bar)). Since
  [the gaps were closed](#upstream-behaviour-gaps-closed) it is also placed
  for that size, a widget and a rule-pinned window are asked like any other,
  and of several that appear together every one is asked, in turn.

### Limits of sizing

- **Run on fixture windows only.** `tests/e2e/scoped-sizing.sh` resizes
  AppKit fixture windows and an Electron window through every action here. No
  application of the owner's has been resized: how each one clamps, a window
  with a sheet or an attached child window (no family guard stands before the
  size change in a run without the flag), an application that animates its
  resize, and Stage Manager, which shrinks windows itself, are all untried.
- **With Screen Recording the picture follows by the path a native resize
  already used**: the look at the window after its size request updates the
  stream's size (`-track:`). The test bed has no Screen Recording access, so
  this is by the code and was not seen.
- **A minimum or maximum is not known before asking.** Upstream clamps a
  request to the limits a client declares before it works out the place;
  Accessibility tells no limits, so they are learned from the size the window
  took. `msg resize` and a rule's `size` keep the centre for that size, as
  upstream does for the clamped one, and a fit, a fill and fullscreen place
  the size the window took. What differs from upstream: a request beyond a
  limit is sent to the window each time it is repeated, where upstream's is
  nothing once clamped, and `msg resize` echoes the size asked, not the size
  granted, because it answers before the window does. The run recorded
  [below](#what-has-been-run-for-sizing-without-the-flag) is older than this:
  its case 10 shows the frame left where the size *asked for* put it
  (`[-454, -640, 640, 552]`), which the controller no longer does
  (`readback_keeps_the_center_for_the_size_an_absolute_request_was_granted`
  in `crates/desktop/tests/sizes_flow.rs`); the test's case 10 now asserts
  the centre and has not been run since.
- **A window that was not settable is asked again.** Accessibility's answer
  that a window's size cannot be set (a sheet is up, the application said so)
  holds for that request only; the next sizing action or fullscreen asks
  again.
- **A second window waits.** While one window's size request is unanswered,
  a request for another window answers `a native resize of window N is still
  pending`. Upstream has no such queue. It lasts as long as the first request:
  a fraction of a second for a window that answers, about a second for an
  application that has stopped answering (1.1 seconds in the test, case 15).
- **The three-second answer for an effect nobody answered** is exercised by
  the headless coordinator test only (`tests/e2e/desktop-resize.sh`): in the
  run on windows the adapter's own deadline ended every stalled request first.
- One window at a time. Upstream sizes any number of windows at once; here
  there is one transaction, and a second sizing action is continued, replaced
  or refused as described, never queued. Only a window rule's `size` waits
  its turn.
- **A size that does not fit the screen from where the real window sits
  moves the real window first.** macOS grants no size that would carry a
  window past the visible area of its screen (the owner's run of 2026-10-10:
  2056x1329 asked of a window at (223,39), answered with the 1833x1290 it
  had). The adapter therefore writes a native position before the size, the
  least that makes room, and a size larger than the visible area is asked from
  the area's corner and comes back clamped to it: on a 2056x1329 display under
  a 39 point menu bar a fullscreen ends at 2056x1290. The place on the canvas
  and the camera do not change (case 19 of the test); the trace line ends
  `moved=1`. The real window is not put back afterwards, and one with a
  maximum size is moved to the corner all the same when it is asked for more
  than the screen (case 10's window is). Tried on an AppKit fixture window on
  one display; with two displays the screen is the one that holds most of the
  window, by the code.
- A native window's minimum and maximum size are unknown before asking. The
  request is sent as computed and the window clamps it; for a fit that leaves
  the window at the fit's top-left with the size it accepted.
- A sizing action's transaction skips the check a handle drag makes before it
  begins, that the window's own extent still equals the observed one. Without
  the flag the first read of the transaction takes the size the window has as
  its starting point; under the flag the driver's root-only guard and the
  controller's comparison of the first read with the committed size stand in
  for it, and a window that fails either is not resized.
- A window resized in its own application has that size on the canvas within
  a second (case 14 of the test), and a sizing action on it starts from there.
  A step pressed in that second is measured from the size the canvas still
  had. Under the flag such a window keeps its old size on the canvas and a
  sizing action on it fails, as before.
- Escape cancels nothing without the flag: there is no monitor, and a size
  request ends by itself. Under the flag it cancels as before.
- Quitting while a size is owed waits for the window's answer (`Quit pending:
  waiting for native resize result`), five seconds at most without the flag.
- A window that appears by itself begins a size transaction from its own
  attach reply only for a window rule's `size`; the shell hands that reply to
  the same hook as an action's, before it starts the window's capture. A
  ruled window that had to wait begins its own in the reply to the result
  that ended the transaction before it: the resize coordinator performs that
  effect like any other, and the shell takes the transaction it names for a
  sizing action's, so a press does not cancel it and `msg` is answered while
  it runs. No rule has matched a window in the app, so all of this is compiled
  and read only. A window attached from the chooser is never asked.
- Nothing on screen says that a ruled window is waiting its turn, and its
  opening is held back for the size only from the moment its own transaction
  begins. One of several ruled windows that appear together may therefore be
  seen opening at its own size and growing afterwards, where upstream shows
  each at the size its rule gave it.
- A ruled window that takes another size than its rule names keeps the
  top-left of the frame it was placed for. Upstream places the size the
  window took: its `position` centres that size, and its pin and its
  placement are worked out for it.
- A widget and a screen-pinned window are sized by nothing but their own
  rule's `size` as they appear: not by an action, not by `msg resize`, not by
  hand. Upstream also resizes a pinned window in screen space by its resize
  binding; here that press raises and focuses it and says it is not resized.
  This is a decision of the port, not a limit of a Mac window.
- The shell tells the controller it can resize before the
  canvas, and so the resize coordinator, exists. No window has a live source
  until the canvas is open, so no transaction can begin in between.
- Fullscreen runs on this same transaction and has its own section and
  limits: [Fullscreen](#fullscreen).

### What has been run for sizing without the flag

Historical evidence: invocations of `--experimental-native-resize` in this
subsection refer to the mode removed on 2026-10-12.

On 2026-10-11, macOS 27.2, Apple Silicon, from a shell with Accessibility and
no Screen Recording access, in the tree that made sizing run in every normal
run:

- `tests/e2e/scoped-sizing.sh`: four AppKit fixture applications of the test's
  own (A resizable; B with a content minimum of 300x260 and a maximum of
  640x520; C with a resize increment of 37x23; R, whose window appears while
  Infinify runs and whose title a rule with `size = [480, 360]` names) and a
  decoy outside the scope, managed by
  `Infinify --windowed 1100x700 --debug-pointer --no-hover-forwarding --only-pid …`
  on a private state, config and socket. Every size is asked over the socket;
  each fixture reports its own window's bounds; `canvas` is `msg state`'s size
  for the window. After each step a press and release is made on the window's
  tile through `DebugPointer` and must land once in the window's plain view,
  within two points of its middle at the size the window then has. Sizes are
  frame sizes: a fixture's title bar is 32 points, so a content minimum of
  300x260 is a frame of 300x292. Its output, less the evidence path:

```
SKIPPED: Electron case, INFINIFY_E2E_ELECTRON is unset
ok: adopts exactly the scope: [(1, 'Size fixture C 68251', [420, 502]), (2, 'Size fixture B 68251', [420, 502]), (3, 'Size fixture A 68251', [420, 502])]
ok: Screen Recording: not granted: tiles have no picture
ok: mod+m (fit-window) and mod+f (toggle-fullscreen) are bindings that run here: {'sizing bindings that run': ['mod+f=toggle-fullscreen', 'mod+m=fit-window', 'mod+shift+m=fit-window-snapped'], 'do not run': 'debug: key bindings that do not run here: '}
ok: zoom is 1: 1.0
ok: adoption: the canvas has the size of A's window: {'native': [420, 502], 'canvas': [420, 502]}
ok: the canvas panel's corner on screen: [478.0, 334.0]
ok: adoption: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [210, 147], 'plain_up': [210, 147]}, 'want': [210.0, 147.0]}
ok: 2: grow-window right: {'native': [450, 502], 'canvas': [450, 502]}
ok: 2: the opposite edge stays: {'before': [340, 99, 420, 502], 'after': [340, 99, 450, 502]}
ok: 2: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [225, 147], 'plain_up': [225, 147]}, 'want': [225.0, 147.0]}
ok: 3: grow-window left: {'native': [480, 502], 'canvas': [480, 502]}
ok: 3: the opposite edge stays: {'before': [340, 99, 450, 502], 'after': [310, 99, 480, 502]}
ok: 3: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [240, 147], 'plain_up': [240, 147]}, 'want': [240.0, 147.0]}
ok: 4: shrink-window right: {'native': [450, 502], 'canvas': [450, 502]}
ok: 4: the opposite edge stays: {'before': [310, 99, 480, 502], 'after': [310, 99, 450, 502]}
ok: 4: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [225, 147], 'plain_up': [225, 147]}, 'want': [225.0, 147.0]}
ok: 5: grow-window down-right: {'native': [471, 523], 'canvas': [471, 523]}
ok: 5: the opposite edge stays: {'before': [310, 99, 450, 502], 'after': [310, 99, 471, 523]}
ok: 5: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [235.5, 147], 'plain_up': [235.5, 147]}, 'want': [235.5, 147.0]}
ok: 6: msg resize 500 400: {'native': [500, 400], 'canvas': [500, 400]}
ok: 6: the top-left moves by half the difference: {'before': [310, 99, 471, 523], 'after': [296, 160, 500, 400]}
ok: 6: msg resize reads the size: 500 400
ok: 6: the same request again resizes nothing: []
ok: 6: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [250, 147], 'plain_up': [250, 147]}, 'want': [250.0, 147.0]}
ok: 7: fit-window: {'native': [1068, 668], 'canvas': [1068, 668]}
ok: 7: mode fit at zoom 1: {'mode': 'Fit', 'zoom': 1.0}
ok: 7: the fit window sits the outer gap inside the canvas: [494, 350, 1068, 668]
ok: 7: the panel corner is where it was: [478.0, 334.0]
ok: 7 fit: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [534, 147], 'plain_up': [534, 147]}, 'want': [534.0, 147.0]}
ok: 7: fit-window again: {'native': [500, 400], 'canvas': [500, 400]}
ok: 7: mode normal again: Normal
ok: 7 unfit: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [250, 147], 'plain_up': [250, 147]}, 'want': [250.0, 147.0]}
ok: 8: fill-window: {'native': [1068, 668], 'canvas': [1068, 668]}
ok: 8: mode fill: Fill
ok: 8: the filled window sits the outer gap inside the canvas: [494, 350, 1068, 668]
ok: 8 fill: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [534, 147], 'plain_up': [534, 147]}, 'want': [534.0, 147.0]}
ok: 8: fill-window again: {'native': [500, 400], 'canvas': [500, 400]}
ok: 8: the frame from before the fill: {'before': [296, 160, 500, 400], 'after': [296, 160, 500, 400]}
ok: 8 unfill: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [250, 147], 'plain_up': [250, 147]}, 'want': [250.0, 147.0]}
ok: 9: B is a snap gap to the right of A: {'a': [296, 160, 500, 400], 'b': [808, 160, 420, 502]}
ok: 9: fit-window-snapped: {'native': [1068, 668], 'canvas': [1068, 668]}
ok: 9: B moved by A's right edge: {'a': [[296, 160, 500, 400], [12, 26, 1068, 668]], 'b': [[808, 160, 420, 502], [1092, 160, 420, 502]]}
ok: 9: B's own window was not resized: {'native': [420, 502], 'requests': []}
ok: 9: fit-window-snapped again: {'native': [500, 400], 'canvas': [500, 400]}
ok: 9: B is back: {'before': [808, 160, 420, 502], 'after': [808, 160, 420, 502]}
ok: 9: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [250, 147], 'plain_up': [250, 147]}, 'want': [250.0, 147.0]}
ok: 10: below the minimum ends at the minimum: {'native': [300, 292], 'canvas': [300, 292]}
ok: 10: the request was answered clamped: ['debug: native resize pid=68264 wid=99303 requested=100x100 outcome=clamped observed=1 actual=300x292']
ok: 10 minimum: a click on the tile of b lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [150, 147], 'plain_up': [150, 147]}, 'want': [150.0, 147.0]}
ok: 10: above the maximum ends at the maximum: {'native': [640, 552], 'canvas': [640, 552]}
ok: 10: the request was answered clamped: ['debug: native resize pid=68264 wid=99303 requested=2000x2000 outcome=clamped observed=1 actual=640x552']
ok: 10: where the request for 2000x2000 left the frame, as upstream writes it: [-454, -640, 640, 552]
ok: 10 maximum: a click on the tile of b lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [320, 147], 'plain_up': [320, 147]}, 'want': [320.0, 147.0]}
ok: 11: a size off the increment: {'native': [494, 548], 'canvas': [494, 548]}
ok: 11: ends on a whole step within one step of the request (snapped by AppKit): {'start': [420, 502], 'asked': [509, 557], 'took': [494, 548]}
ok: 11: a click on the tile of c lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [247, 147], 'plain_up': [247, 147]}, 'want': [247.0, 147.0]}
ok: 12 before: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [250, 147], 'plain_up': [250, 147]}, 'want': [250.0, 147.0]}
ok: 12: toggle-fullscreen, the size the window took of 1100x700: [1100, 700]
ok: 12: the output's fullscreen entry names A: [{'app_id': 'org.infinify.scope-fixture', 'id': 3, 'output': 'windowed', 'title': 'Size fixture A 68251'}]
ok: 12: the tile has the window's size, at the corner or centred: {'tile': [478, 334, 1100, 700], 'want': [478.0, 334.0, 1100, 700]}
ok: 12 fullscreen: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [550, 147], 'plain_up': [550, 147]}, 'want': [550.0, 147.0]}
ok: 12: toggle-fullscreen again gives the size back: {'native': [500, 400], 'canvas': [500, 400]}
ok: 12: the place, the camera and the zoom from before: {'before': {'frame': [296, 160, 500, 400], 'camera': [546.0, -360.0], 'zoom': 1.0, 'origin': [518, 417]}, 'after': {'frame': [296, 160, 500, 400], 'camera': [546.0, -360.0], 'zoom': 1.0, 'origin': [518, 417]}}
ok: 12: the native origin, which nothing here sets: {'before': [518, 417], 'after': [518, 417], 'moved by macOS': False}
ok: 12 after: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [250, 147], 'plain_up': [250, 147]}, 'want': [250.0, 147.0]}
ok: 13: B at 400x300: {'native': [400, 300], 'canvas': [400, 300]}
ok: 13 before: a click on the tile of b lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [200, 147], 'plain_up': [200, 147]}, 'want': [200.0, 147.0]}
ok: 13: fullscreen at the maximum, centred on the canvas: {'tile': [708, 408, 640, 552], 'window': [640, 552]}
ok: 13 fullscreen: a click on the tile of b lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [320, 147], 'plain_up': [320, 147]}, 'want': [320.0, 147.0]}
ok: 13: and back: {'native': [400, 300], 'canvas': [400, 300]}
ok: 13: the place, the camera and the zoom from before: {'before': {'frame': [346, 210, 400, 300], 'camera': [546.0, -360.0], 'zoom': 1.0}, 'after': {'frame': [346, 210, 400, 300], 'camera': [546.0, -360.0], 'zoom': 1.0}}
ok: 13 after: a click on the tile of b lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [200, 147], 'plain_up': [200, 147]}, 'want': [200.0, 147.0]}
ok: 14: a size the application set itself reaches the canvas: {'native': [560, 430], 'canvas': [560, 430]}
ok: 14: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [280, 147], 'plain_up': [280, 147]}, 'want': [280.0, 147.0]}
ok: 14: a step from that size: {'native': [590, 430], 'canvas': [590, 430]}
ok: 15: another window's request at once: error: a native resize of window 1 is still pending
ok: 15: it was refused as pending, in the controller's words: error: a native resize of window 1 is still pending
ok: 15: the other window was resized: {'native': [520, 410], 'canvas': [520, 410]}
ok: 15: the stuck request ended and another window was sized: {'seconds': 1.11, 'C had not reported for': 1.11, 'requests of C': ['debug: native resize pid=68266 wid=99305 requested=605x617 outcome=readback_failed observed=0 actual=494x548']}
ok: 15: C was still not answering when that happened: 1.11
ok: 15: C's setter was reported unanswered: ['debug: native resize pid=68266 wid=99305 requested=605x617 outcome=readback_failed observed=0 actual=494x548']
ok: 15: the canvas has the size C's window took: {'native': [605, 617], 'canvas': [605, 617]}
ok: 15: a click on the tile of c lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [302.5, 147], 'plain_up': [302.5, 147]}, 'want': [302.5, 147.0]}
ok: 16: the dead application's window left the canvas: {'seconds': 0.35}
ok: 16: and was resized: {'native': [500, 400], 'canvas': [500, 400]}
ok: 17 before: a click on the tile of b lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [200, 147], 'plain_up': [200, 147]}, 'want': [200.0, 147.0]}
ok: 17: the camera and the zoom from before the fullscreen: {'before': {'camera': [48550.0, -350.0], 'zoom': 1.0}, 'after': {'camera': [48550.0, -350.0], 'zoom': 1.0}}
ok: 17: and was resized: {'native': [520, 420], 'canvas': [520, 420]}
ok: 18: the rule's size [480, 360]: {'native': [480, 360], 'canvas': [480, 360]}
ok: 18: a click on the tile of r lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [240, 147], 'plain_up': [240, 147]}, 'want': [240.0, 147.0]}
ok: 21: decoy took no event, was never activated and has its bounds: {'bounds': [968, 417, 420, 502], 'activations': 0}
ok: 21: every pid acted on is in the scope: {'named': [68262, 68264, 68266, 68268], 'scope': [68262, 68264, 68266, 68268], 'decoy': 68270}
ok: 21: no press or tile was refused as unsettled: []
ok: 21: what the native adapter answered, by outcome: {'size read observed': 52, 'resize applied': 20, 'resize clamped': 5, 'resize readback_failed': 1, 'size read unavailable': 1, 'resize stale_identity': 1, 'size read stale_identity': 1}
ok: 20 before: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [260, 147], 'plain_up': [260, 147]}, 'want': [260.0, 147.0]}
ok: 20: A is fullscreen before the quit: [1100, 700]
ok: quit within 8 s
ok: a window left fullscreen has its size back after quit: {'before fullscreen': [520, 420], 'after quit': [520, 420]}
ok: decoy untouched to the end: {'bounds': [968, 417, 420, 502], 'activations': 0}
ok: no press or tile was ever refused as unsettled: []
PASS: scoped sizing: steps, msg resize, fit, fill, fit snapped, minimum, maximum and increment, fullscreen, a size the application set, an application that stops answering or dies mid-request, a fullscreen window closed, a rule size, quit from fullscreen; decoy untouched
```

  What it shows beyond the sizes: AppKit applies a window's content minimum,
  maximum and resize increments to a size set through Accessibility (the
  fixture's own increment snap never ran); macOS did not move a window whose
  size was set, here (case 12); a fullscreen window was asked for 1100x700,
  the canvas panel's size, and took it; an application stalled inside its
  resize answered neither the setter (`readback_failed`, unobserved) nor the
  read after it (`unavailable`), the request ended in about a second with
  `Window not resized: the window did not answer the size request in time`,
  and when the application answered again the canvas had the size its window
  had meanwhile taken. Not shown: any of it with a picture, any application
  of the owner's, a chord.
- The same with `INFINIFY_E2E_ELECTRON` set to a generic Electron binary adds
  an Electron window (every other line as above); its block:

```
ok: 22 before: a click on the tile of e lands once, within 2 points: {'delta': {'web_down': 1, 'web_up': 1}, 'last': {'web_down': [210, 249], 'web_up': [210, 249]}, 'want': [210.0, 249.0]}
ok: 22: adoption: {'native': [420, 470], 'canvas': [420, 470]}
ok: 22: grow-window right: {'native': [450, 470], 'canvas': [450, 470]}
ok: 22 step: a click on the tile of e lands once, within 2 points: {'delta': {'web_down': 1, 'web_up': 1}, 'last': {'web_down': [225, 249], 'web_up': [225, 249]}, 'want': [225.0, 249.0]}
ok: 22: msg resize 500 400: {'native': [500, 400], 'canvas': [500, 400]}
ok: 22 absolute: a click on the tile of e lands once, within 2 points: {'delta': {'web_down': 1, 'web_up': 1}, 'last': {'web_down': [250, 214], 'web_up': [250, 214]}, 'want': [250.0, 214.0]}
ok: 22: fit-window: {'native': [1068, 668], 'canvas': [1068, 668]}
ok: 22 fit: a click on the tile of e lands once, within 2 points: {'delta': {'web_down': 1, 'web_up': 1}, 'last': {'web_down': [534, 348], 'web_up': [534, 348]}, 'want': [534.0, 348.0]}
ok: 22: fit-window again: {'native': [500, 400], 'canvas': [500, 400]}
ok: 22: toggle-fullscreen, the size the window took of 1100x700: [1100, 700]
ok: 22 fullscreen: a click on the tile of e lands once, within 2 points: {'delta': {'web_down': 1, 'web_up': 1}, 'last': {'web_down': [550, 364], 'web_up': [550, 364]}, 'want': [550.0, 364.0]}
ok: 22: toggle-fullscreen again: {'native': [500, 400], 'canvas': [500, 400]}
ok: 22 after: a click on the tile of e lands once, within 2 points: {'delta': {'web_down': 1, 'web_up': 1}, 'last': {'web_down': [250, 214], 'web_up': [250, 214]}, 'want': [250.0, 214.0]}
```

- `tests/e2e/scoped-windows.sh`: passed unchanged, its refusal of `--only-pid`
  with `--experimental-native-resize` and its launch without a scope (which
  manages nothing without Screen Recording access) included.
- `tests/e2e/desktop-resize.sh`: passed, with the readback cases of
  `resize-regression.m`: no result invalidates a capture, the watchdog
  discharges an unanswered read and an unanswered setter, a driver that
  returns nothing and a result the controller refuses leave no obligation, and
  a transaction nobody is performing is ended the second time it is seen.
- `cargo test -p driftwm-desktop --test <name>` for `sizes_flow` (37),
  `native_resize_flow` (28), `fullscreen_flow` (24), `rules_flow`, `ipc_flow`,
  `config_flow`, `gesture_flow`, `platform_actions_flow`, `usable_tap_flow`,
  `effects_flow`, `navigation_actions_flow` and `render_flow`: all passed.
  `cargo clippy -p driftwm-desktop --tests`: no warning.

### What has been run for sizing

Historical evidence: invocations of `--experimental-native-resize` in this
subsection refer to the mode removed on 2026-10-12.

On 2026-10-10, macOS 27.2, Apple Silicon, in this tree:

- `./scripts/build-app.sh`: built and ad-hoc signed; nothing launched.
- `cargo fmt -p driftwm-desktop -- --check` and
  `cargo clippy -p driftwm-desktop --all-targets -- -D warnings`: clean.
- `cargo test -p driftwm-desktop --test sizes_flow --test native_resize_flow
  --test view_actions_flow --test navigation_actions_flow --test ipc_flow
  --test controller_flow --test lifecycle_flow --test gesture_flow --test
  motion_flow --test config_flow`: all passed, `sizes_flow` with 21 scenarios.
  They cross the exported C ABI and JSON; the test answers every resize effect
  with a made-up native result. Read from the controller library by a
  throwaway program, the default key table lists 45 bindings, of which 41 run
  without the capability and 43 with it. (That was the sizing work by itself,
  before it was built together with window rules, rendering and the pointer
  policy; [below](#what-has-been-run-for-sizing-with-everything-else-built-in)
  are the numbers of the combined build.)
- `./tests/e2e/desktop-navigation.sh`: PASS. It runs the navigation
  coordinator headless against the Rust library; that coordinator is
  unchanged, and the script does not go through the shell's reply hook.
- Two launches of the built app as `--windowed 1100x700` on a private scene
  (three seeded detached placeholders, 640x420 at (200, 150), 900x600 at
  (1500, -300) and 560x380 at (-900, 700)), a private config (`resize_step =
  40`, `[snap] gap = 12`, `outer_gap = 12`, `[zoom] fit_padding = 80`) and a
  private socket, driven by a script through `Infinify msg`. Neither had
  Screen Recording access, so no real window was on the canvas, and a guard in
  the script would have ended the run before any action had one been. Nothing
  from them is saved as evidence.

  Without the flag, after `msg focus --id 1`:

  ```
  $ msg action fit-window
  error: action not implemented on macOS yet: fit-window
  $ msg action fit-window-snapped
  error: action not implemented on macOS yet: fit-window-snapped
  $ msg action fill-window
  error: action not implemented on macOS yet: fill-window
  $ msg action grow-window right
  error: action not implemented on macOS yet: grow-window
  $ msg action shrink-window right
  error: action not implemented on macOS yet: shrink-window
  $ msg resize --id 1 800 600
  error: resize is not implemented on macOS yet: native layout resize is not available
  ```

  With `--experimental-native-resize`, the same requests on the same
  placeholders:

  ```
  $ msg action fit-window
  ok
  $ msg action fit-window-snapped
  ok
  $ msg action fill-window
  ok
  $ msg action grow-window right
  error: grow-window needs a live window: a stand-in has no native size to change
  $ msg action shrink-window right
  error: shrink-window needs a live window: a stand-in has no native size to change
  $ msg resize --id 1 800 600
  error: this window has no native size to set: it is a stand-in or has no live window
  ```

  The three `ok` answers changed nothing: `msg --json state` afterwards showed
  window 1 at its seeded position and size with `"mode": "Normal"`. That the
  answers differ from the unflagged run shows the app told the controller it
  can resize, and that this survived the scene load.

  In both launches, with window 2 moved beside window 1 at the snap gap (`msg
  move --id 2 1302 -450`) and window 1 focused, `msg action
  zoom-to-fit-snapped` took the view from camera `550 -318` at zoom 1 to
  camera `976 -450` at zoom `0.6056701030927835`: the centre of the two
  windows' bounding box, and (1100 - 160) / 1552, the third window left out. A
  second one returned to `550 -318` at zoom 1. Both apps exited with status 0
  on SIGTERM and removed their socket.

Not run: any size transaction in the app. No window on those canvases had a
live source, so no sizing action began one, the shell's hook handed nothing to
the resize coordinator, and no native window was read or resized. Also unrun:
`tests/e2e/desktop-resize.sh` (the resize coordinator's own headless
regression; that file is unchanged), every hot key, mouse binding, trackpad
gesture and hot corner that fires a sizing action, key repeat on
`grow-window`, Escape during a transaction, the status notes, anything drawn,
and more than one display.

### What has been run for sizing with everything else built in

Historical evidence: invocations of `--experimental-native-resize` in this
subsection refer to the mode removed on 2026-10-12.

The same day and machine (macOS 27.2, Apple Silicon), in one tree with window
rules, widgets and pins, the Metal renderer and the pointer policy:

- `./scripts/build-app.sh`: built and ad-hoc signed; nothing launched.
- `cargo fmt -p driftwm-desktop -- --check` and
  `cargo clippy -p driftwm-desktop --all-targets -- -D warnings`: clean.
- `cargo test -p driftwm-desktop` for `sizes_flow`, `native_resize_flow`,
  `pointer_flow`, `rules_flow`, `render_flow`, `gesture_flow`, `motion_flow`,
  `navigation_actions_flow`, `platform_actions_flow`, `lifecycle_flow`,
  `config_flow`, `ipc_flow`, `view_actions_flow`, `controller_flow`,
  `navigation_flow` and `focus_cycle_flow`: all 214 scenarios passed,
  `sizes_flow` with 30 and `rules_flow` with 22. The nine added to
  `sizes_flow` and the one added to `rules_flow` are the joins: every sizing
  action passing over a widget and a pinned window, a pin keeping a fit, fills,
  snapped fits and `zoom-to-fit-snapped` seeing only the windows that snap,
  the three refusals of a drag, a size still owed holding the pointer, a
  pick's return to a fill view, centring past a pinned window, `send-to-output`
  on a filled and on a pinned window, a resize drag elsewhere, and a rule's
  `size` with the capability on. As before, the test answers every resize
  effect with a made-up native result.
- `./tests/e2e/desktop-navigation.sh`: PASS.
- Two throwaway programs against the controller library, outside the
  repository. One read the default tables: 45 key bindings, of which 42 run
  without the capability and 44 with it; of the 35 action names of upstream's
  grammar six are refused by name without it (`grow-window`, `shrink-window`,
  `fit-window`, `fit-window-snapped`, `fill-window`, `toggle-fullscreen`) and
  one with it (`toggle-fullscreen`). The other sent the same requests to the
  tree as it was before the sizing work was merged into it and to the merged
  one, and compared 168 replies and the saved scene file, with the capability never sent and again with it sent as
  `false`, on a scene with a canvas window, a widget, a rule-pinned window
  and a window whose rule names a `size`: the five sizing actions by
  `action`, by IPC and with no output, the hot corner and the pinch bound to
  `fit-window`, IPC `Resize` on each window, `begin_drag`, `begin_resize` and
  `begin_native_resize` on each, `bindings`, `mouse_binding`, `State`,
  `hover` and the snapshot. The raw replies were identical but for two
  things: every `snapshot.windows[]` entry has `"mode": null`, and
  `bindings` reports `zoom-to-fit-snapped` implemented. Neither program is in
  the repository.
- Five launches of the built app as `--windowed 1100x700` on the same seeded
  scene (three detached placeholders), a private config (`resize_step = 40`,
  `[snap] gap = 12`, `outer_gap = 12`, `[zoom] fit_padding = 80`) and a
  private socket, driven by a script through `Infinify msg`. The first was
  ended after a second by the script's own guard, which misread the state
  reply; nothing had been asked of the app. The two below were then run, and
  run once more after a last change to the rule-size path, with the same
  answers line for line and the same screenshot byte for byte. None had
  Screen Recording access,
  so no real window was on the canvas, and the guard checked before any
  sizing action that every window was one of the three placeholders. Nothing
  from them is saved as evidence.

  Without the flag (3 seconds each time): `state` listed the three placeholders;
  `action center-nearest right` flew to the Browser placeholder (camera
  `1950 -0`, focus `#2`); `action pan-viewport right` moved the camera to
  `2050 -0`; `action zoom-to-fit` went to camera `750 -390` at zoom
  `0.28484848484848485` and a second one back to `2050 -0` at zoom 1;
  `pin --id 1 on` answered `stand-ins can't be pinned`, `opacity --id 1 0.5`
  answered `no window with id 1` and `action toggle-pin-to-screen` answered
  `ok`; and then

  ```
  $ msg action fit-window
  error: action not implemented on macOS yet: fit-window
  $ msg action fit-window-snapped
  error: action not implemented on macOS yet: fit-window-snapped
  $ msg action fill-window
  error: action not implemented on macOS yet: fill-window
  $ msg action grow-window right
  error: action not implemented on macOS yet: grow-window
  $ msg action shrink-window right
  error: action not implemented on macOS yet: shrink-window
  $ msg resize --id 1 800 600
  error: resize is not implemented on macOS yet: native layout resize is not available
  ```

  With the Terminal placeholder moved one snap gap right of the Browser one
  (`msg move --id 3 2692 110`) and the Browser one focused, `action
  zoom-to-fit-snapped` took the view to camera `2236 -0` at zoom
  `0.6385869565217391`: the centre of the two frames' bounding box and
  (1100 - 160) / 1472, the third window left out. `msg screenshot` of that
  view wrote a 1723 x 996 PNG, opened and looked at: the dot grid and the two
  placeholders side by side, each a dark rounded tile with its bundle
  identifier and a close mark, inside the padding. A second
  `zoom-to-fit-snapped` returned to `2050 -0` at zoom 1.

  With `--experimental-native-resize` (1 and 2 seconds), after `focus --id 1`:

  ```
  $ msg action fit-window
  ok
  $ msg action fit-window-snapped
  ok
  $ msg action fill-window
  ok
  $ msg action grow-window right
  error: grow-window needs a live window: a stand-in has no native size to change
  $ msg action shrink-window right
  error: shrink-window needs a live window: a stand-in has no native size to change
  $ msg resize --id 1 800 600
  error: this window has no native size to set: it is a stand-in or has no live window
  ```

  The three `ok` answers changed nothing: `--json state` afterwards had every
  window at its seeded position and size with `"mode": "Normal"`.
  `zoom-to-fit-snapped` on the lone focused placeholder centred it (camera
  `520 -360`, zoom 1) and returned, `center-nearest right` flew to the
  Browser placeholder and `pin --id 1 on` answered `stand-ins can't be
  pinned`. All four full launches exited with status 0 on SIGTERM and removed
  their socket.

**No live window existed in any of these launches, so no size transaction ran
in the app**: no sizing action and no rule began one, the hook handed nothing
to the resize coordinator, and no native window was read or resized. No rule
was resolved there either (the config had none), no widget or pinned window
existed, and no pointer event was sent, so everything in this section that
joins sizing to rules, pins, the pointer and pick mode ran only in the
controller scenarios. Still unrun as well: `tests/e2e/desktop-resize.sh`,
every hot key, mouse binding, gesture and hot corner that fires a sizing
action, key repeat, Escape during a transaction, and more than one display.

## Resizing a window with the pointer

In every normal run, with no flag, DriftWM's pointer resize works on real
windows:

- **⌥ right drag on a window** (`resize-window`, upstream's default
  `alt+right`) raises and focuses the window and resizes it. Where the press
  falls decides what moves, by upstream's 3×3 grid over the window: a corner
  cell moves that corner, an edge cell that edge, and the middle resizes from
  the bottom right. The opposite edge or corner stays where it is.
- **⌥⇧ right drag** (`resize-window-snapped`) does the same and carries the
  snap cluster: the windows snapped to the moving edges move with them, by as
  much as the window grew or shrank, without being resized.
- **A left drag just outside a window's frame** resizes by that edge
  (`[mouse] resize_on_border`, default true): the band is 8 canvas units
  around the frame, so it scales with the zoom. With
  `decoration_resize_snapped = true` that drag carries the cluster. A binding
  whose modifiers are held on that window wins over the border.
- **A window rule's `preserve_aspect_ratio`** keeps the width to height the
  window has when the drag begins: an edge drives its own axis and the other
  follows, a corner follows the axis dragged farther. Such a resize does not
  snap and carries no cluster.
- **⌥ three-finger swipe over a window** (`alt+3-finger-swipe`, and with ⇧ the
  snapped one) begins the same resize from the pointer's place and follows the
  fingers. This has been run in controller scenarios only.

Each size the drag asks is asked of the real window through Accessibility, and
the canvas shows the size the window then has. One size is asked at a time:
while the window is answering, later pointer motion only replaces the size
that waits, so a fast drag asks a few sizes, not one per event (thirty events
asked three sizes of a fixture in the run recorded below). What is drawn therefore follows the pointer by
one request, and a window that grants another size than was asked (a minimum,
a maximum, a resize increment) is shown at the size it took. Sizes snap to
other windows as a move does (`[snap]`). When the button lifts the last size
is let through, the window is read once more, and the canvas and the window
agree. Nothing waits for a capture and no input is held: a click on another
window lands during a resize that has not been answered yet.

A drag ends without its release when the window will not be resized at all
(the press has then only raised and focused it), when the window closes, and
when its application stops answering: the size request then ends by itself
within the adapter's deadline and one more read. The rest of that press does
nothing, and the next press starts afresh.

### Where a Mac window cannot follow DriftWM's

- **A left or top drag moves the tile, not the real window's corner.** A Mac
  window's origin is its top-left and a size request keeps it, so the real
  window grows right and down wherever the drag was taken. Upstream shows the
  opposite edge standing still, and so does the canvas: the tile's origin is
  moved by what the size changed. The real window's own place is the shell's
  affair as for every other size request (it is moved only to make room on its
  screen).
- **Limits are not known before asking.** Upstream clamps to the limits its
  client declares and never asks for more. Here a size past a limit is asked
  and refused, about an eighth of a second each time while the pointer keeps
  moving (by the adapter's polling constants; not measured); a pointer at rest
  asks nothing. The snap cluster follows the size
  granted, so it stops with the window.
- **macOS grants no size larger than the screen's visible area**, and the
  real window is moved first when a larger size has no room where it sits.
- **A screen-pinned window is not resized**, where upstream resizes it in
  screen space. The press raises and focuses it and says so. A decision of
  the port, for the owner to confirm.
- **One size transaction at a time.** While a resize drag lasts, a sizing
  action, a fullscreen toggle and `msg resize`, of this or any other window,
  are refused as pending. A second resize press while the last one is still
  settling only raises and focuses the window.
- **The drag ends when its own button lifts**, where upstream's ends with the
  last of several buttons.
- **The border is on the canvas.** A real window's own edges lie under the
  canvas and no pointer reaches them. The rest is a decision of the port, not
  a limit of a Mac window: the band exists only where no window's frame covers
  it, a lower window's included (upstream's topmost band wins over the body of
  a window beneath it), a press it does not take is a canvas press (upstream
  still counts the band as the window for bindings), and a stand-in, a widget,
  a pinned and a fullscreen window have none.
- **Resize cursors** now use AppKit's edge/corner shapes over the accepted
  canvas border and during the matching native resize transaction. The source
  is compiled but has not been exercised with a physical pointer.

### What has been run for the pointer resize

On 2026-10-11, macOS 27.2, Apple Silicon, one 2056x1329 display, from a shell
with Accessibility and no Screen Recording access, on the build of this tree:

- `tests/e2e/scoped-resize-drag.sh`: eight AppKit fixture applications of the
  test's own (A, N, K and H resizable; B with a content minimum of 300x260 and
  a maximum of 640x520; C with a resize increment of 37x23; F not resizable;
  P, whose title a rule with `preserve_aspect_ratio = true` names) and a decoy
  outside the scope, managed by
  `Infinify --windowed 1100x700 --debug-pointer --no-hover-forwarding --only-pid …`
  on a private state, config and socket, with `[snap] gap = 12`,
  `distance = 16`, `break_force = 24` and upstream's default bindings. Every
  press, drag and release is a `DebugPointer` request: an event handed to the
  canvas view's own handlers, as described under `--debug-pointer` above. Each
  fixture reports its own window's bounds; `canvas` is `msg state`'s size for
  the window; a frame is `[x, y, width, height]` on the canvas. After each
  case a press and release on the window's tile must land once in its plain
  view. Sizes are frame sizes: a fixture's title bar is 32 points. Its output,
  less the evidence path:

```
ok: adopts exactly the scope: [(1, 'Drag fixture H 38755', [420, 502]), (2, 'Drag fixture A 38755', [420, 502]), (3, 'Drag fixture B 38755', [420, 502]), (4, 'Ratio P 38755', [420, 502]), (5, 'Drag fixture K 38755', [420, 502]), (6, 'Drag neighbour N 38755', [420, 502]), (7, 'Drag fixture F 38755', [420, 502]), (8, 'Drag fixture C 38755', [420, 502])]
ok: Screen Recording: not granted: tiles have no picture
ok: zoom is 1: 1.0
ok: 1: N is focused first: a click on the tile of n lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [210, 147], 'plain_up': [210, 147]}, 'want': [210.0, 147.0]}
ok: 1: N holds the focus before the first press: [6]
ok: 1 top_left from (0.17, 0.17): a at 480x360: {'native': [480, 360], 'canvas': [480, 360]}
ok: 1 top_left from (0.17, 0.17): the press is the right button's, bound to resize-window: debug: pointer down button=1 trigger=right binding=resize_window window=#2
ok: 1 top_left from (0.17, 0.17): the grab resizes the top_left edge: debug: resize grab transaction=2 window=#2 edges=top_left group=0 ratio=0
ok: 1: the press raises and focuses A before any drag: [2]
ok: 1 top_left from (0.17, 0.17): the window and the canvas end at 520x390: {'native': [520, 390], 'canvas': [520, 390]}
ok: 1 top_left from (0.17, 0.17): the opposite edge stays on the canvas: {'before': [110, 170, 480, 360], 'after': [70, 140, 520, 390], 'want': [70, 140, 520, 390]}
ok: 1 top_left from (0.17, 0.17): the native window keeps its own top-left (no setter moved it): {'before': [518, 417, 480, 360], 'after': [518, 417, 520, 390], 'setters': 5}
ok: 1 top_left from (0.17, 0.17): the transaction completed: ['debug: size transaction 2 of #2 ended phase=complete']
ok: 1 top_left from (0.17, 0.17): a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [260, 147], 'plain_up': [260, 147]}, 'want': [260.0, 147.0]}
ok: 1 top from (0.50, 0.17): a at 480x360: {'native': [480, 360], 'canvas': [480, 360]}
ok: 1 top from (0.50, 0.17): the press is the right button's, bound to resize-window: debug: pointer down button=1 trigger=right binding=resize_window window=#2
ok: 1 top from (0.50, 0.17): the grab resizes the top edge: debug: resize grab transaction=4 window=#2 edges=top group=0 ratio=0
ok: 1 top from (0.50, 0.17): the window and the canvas end at 480x390: {'native': [480, 390], 'canvas': [480, 390]}
ok: 1 top from (0.50, 0.17): the opposite edge stays on the canvas: {'before': [90, 155, 480, 360], 'after': [90, 125, 480, 390], 'want': [90, 125, 480, 390]}
ok: 1 top from (0.50, 0.17): the native window keeps its own top-left (no setter moved it): {'before': [518, 417, 480, 360], 'after': [518, 417, 480, 390], 'setters': 5}
ok: 1 top from (0.50, 0.17): the transaction completed: ['debug: size transaction 4 of #2 ended phase=complete']
ok: 1 top from (0.50, 0.17): a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [240, 147], 'plain_up': [240, 147]}, 'want': [240.0, 147.0]}
ok: 1 top_right from (0.83, 0.17): a at 480x360: {'native': [480, 360], 'canvas': [480, 360]}
ok: 1 top_right from (0.83, 0.17): the press is the right button's, bound to resize-window: debug: pointer down button=1 trigger=right binding=resize_window window=#2
ok: 1 top_right from (0.83, 0.17): the grab resizes the top_right edge: debug: resize grab transaction=6 window=#2 edges=top_right group=0 ratio=0
ok: 1 top_right from (0.83, 0.17): the window and the canvas end at 520x390: {'native': [520, 390], 'canvas': [520, 390]}
ok: 1 top_right from (0.83, 0.17): the opposite edge stays on the canvas: {'before': [90, 140, 480, 360], 'after': [90, 110, 520, 390], 'want': [90, 110, 520, 390]}
ok: 1 top_right from (0.83, 0.17): the native window keeps its own top-left (no setter moved it): {'before': [518, 417, 480, 360], 'after': [518, 417, 520, 390], 'setters': 5}
ok: 1 top_right from (0.83, 0.17): the transaction completed: ['debug: size transaction 6 of #2 ended phase=complete']
ok: 1 top_right from (0.83, 0.17): a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [260, 147], 'plain_up': [260, 147]}, 'want': [260.0, 147.0]}
ok: 1 left from (0.17, 0.50): a at 480x360: {'native': [480, 360], 'canvas': [480, 360]}
ok: 1 left from (0.17, 0.50): the press is the right button's, bound to resize-window: debug: pointer down button=1 trigger=right binding=resize_window window=#2
ok: 1 left from (0.17, 0.50): the grab resizes the left edge: debug: resize grab transaction=8 window=#2 edges=left group=0 ratio=0
ok: 1 left from (0.17, 0.50): the window and the canvas end at 520x360: {'native': [520, 360], 'canvas': [520, 360]}
ok: 1 left from (0.17, 0.50): the opposite edge stays on the canvas: {'before': [110, 125, 480, 360], 'after': [70, 125, 520, 360], 'want': [70, 125, 520, 360]}
ok: 1 left from (0.17, 0.50): the native window keeps its own top-left (no setter moved it): {'before': [518, 417, 480, 360], 'after': [518, 417, 520, 360], 'setters': 5}
ok: 1 left from (0.17, 0.50): the transaction completed: ['debug: size transaction 8 of #2 ended phase=complete']
ok: 1 left from (0.17, 0.50): a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [260, 147], 'plain_up': [260, 147]}, 'want': [260.0, 147.0]}
ok: 1 bottom_right from (0.50, 0.50): a at 480x360: {'native': [480, 360], 'canvas': [480, 360]}
ok: 1 bottom_right from (0.50, 0.50): the press is the right button's, bound to resize-window: debug: pointer down button=1 trigger=right binding=resize_window window=#2
ok: 1 bottom_right from (0.50, 0.50): the grab resizes the bottom_right edge: debug: resize grab transaction=10 window=#2 edges=bottom_right group=0 ratio=0
ok: 1 bottom_right from (0.50, 0.50): the window and the canvas end at 520x390: {'native': [520, 390], 'canvas': [520, 390]}
ok: 1 bottom_right from (0.50, 0.50): the opposite edge stays on the canvas: {'before': [90, 125, 480, 360], 'after': [90, 125, 520, 390], 'want': [90, 125, 520, 390]}
ok: 1 bottom_right from (0.50, 0.50): the native window keeps its own top-left (no setter moved it): {'before': [518, 417, 480, 360], 'after': [518, 417, 520, 390], 'setters': 5}
ok: 1 bottom_right from (0.50, 0.50): the transaction completed: ['debug: size transaction 10 of #2 ended phase=complete']
ok: 1 bottom_right from (0.50, 0.50): a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [260, 147], 'plain_up': [260, 147]}, 'want': [260.0, 147.0]}
ok: 1 right from (0.83, 0.50): a at 480x360: {'native': [480, 360], 'canvas': [480, 360]}
ok: 1 right from (0.83, 0.50): the press is the right button's, bound to resize-window: debug: pointer down button=1 trigger=right binding=resize_window window=#2
ok: 1 right from (0.83, 0.50): the grab resizes the right edge: debug: resize grab transaction=12 window=#2 edges=right group=0 ratio=0
ok: 1 right from (0.83, 0.50): the window and the canvas end at 520x360: {'native': [520, 360], 'canvas': [520, 360]}
ok: 1 right from (0.83, 0.50): the opposite edge stays on the canvas: {'before': [110, 140, 480, 360], 'after': [110, 140, 520, 360], 'want': [110, 140, 520, 360]}
ok: 1 right from (0.83, 0.50): the native window keeps its own top-left (no setter moved it): {'before': [518, 417, 480, 360], 'after': [518, 417, 520, 360], 'setters': 5}
ok: 1 right from (0.83, 0.50): the transaction completed: ['debug: size transaction 12 of #2 ended phase=complete']
ok: 1 right from (0.83, 0.50): a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [260, 147], 'plain_up': [260, 147]}, 'want': [260.0, 147.0]}
ok: 1 bottom_left from (0.17, 0.83): a at 480x360: {'native': [480, 360], 'canvas': [480, 360]}
ok: 1 bottom_left from (0.17, 0.83): the press is the right button's, bound to resize-window: debug: pointer down button=1 trigger=right binding=resize_window window=#2
ok: 1 bottom_left from (0.17, 0.83): the grab resizes the bottom_left edge: debug: resize grab transaction=14 window=#2 edges=bottom_left group=0 ratio=0
ok: 1 bottom_left from (0.17, 0.83): the window and the canvas end at 520x390: {'native': [520, 390], 'canvas': [520, 390]}
ok: 1 bottom_left from (0.17, 0.83): the opposite edge stays on the canvas: {'before': [130, 140, 480, 360], 'after': [90, 140, 520, 390], 'want': [90, 140, 520, 390]}
ok: 1 bottom_left from (0.17, 0.83): the native window keeps its own top-left (no setter moved it): {'before': [518, 417, 480, 360], 'after': [518, 417, 520, 390], 'setters': 5}
ok: 1 bottom_left from (0.17, 0.83): the transaction completed: ['debug: size transaction 14 of #2 ended phase=complete']
ok: 1 bottom_left from (0.17, 0.83): a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [260, 147], 'plain_up': [260, 147]}, 'want': [260.0, 147.0]}
ok: 1 bottom from (0.50, 0.83): a at 480x360: {'native': [480, 360], 'canvas': [480, 360]}
ok: 1 bottom from (0.50, 0.83): the press is the right button's, bound to resize-window: debug: pointer down button=1 trigger=right binding=resize_window window=#2
ok: 1 bottom from (0.50, 0.83): the grab resizes the bottom edge: debug: resize grab transaction=16 window=#2 edges=bottom group=0 ratio=0
ok: 1 bottom from (0.50, 0.83): the window and the canvas end at 480x390: {'native': [480, 390], 'canvas': [480, 390]}
ok: 1 bottom from (0.50, 0.83): the opposite edge stays on the canvas: {'before': [110, 155, 480, 360], 'after': [110, 155, 480, 390], 'want': [110, 155, 480, 390]}
ok: 1 bottom from (0.50, 0.83): the native window keeps its own top-left (no setter moved it): {'before': [518, 417, 480, 360], 'after': [518, 417, 480, 390], 'setters': 5}
ok: 1 bottom from (0.50, 0.83): the transaction completed: ['debug: size transaction 16 of #2 ended phase=complete']
ok: 1 bottom from (0.50, 0.83): a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [240, 147], 'plain_up': [240, 147]}, 'want': [240.0, 147.0]}
ok: 1 bottom_right from (0.83, 0.83): a at 480x360: {'native': [480, 360], 'canvas': [480, 360]}
ok: 1 bottom_right from (0.83, 0.83): the press is the right button's, bound to resize-window: debug: pointer down button=1 trigger=right binding=resize_window window=#2
ok: 1 bottom_right from (0.83, 0.83): the grab resizes the bottom_right edge: debug: resize grab transaction=18 window=#2 edges=bottom_right group=0 ratio=0
ok: 1 bottom_right from (0.83, 0.83): the window and the canvas end at 520x390: {'native': [520, 390], 'canvas': [520, 390]}
ok: 1 bottom_right from (0.83, 0.83): the opposite edge stays on the canvas: {'before': [110, 170, 480, 360], 'after': [110, 170, 520, 390], 'want': [110, 170, 520, 390]}
ok: 1 bottom_right from (0.83, 0.83): the native window keeps its own top-left (no setter moved it): {'before': [518, 417, 480, 360], 'after': [518, 417, 520, 390], 'setters': 5}
ok: 1 bottom_right from (0.83, 0.83): the transaction completed: ['debug: size transaction 18 of #2 ended phase=complete']
ok: 1 bottom_right from (0.83, 0.83): a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [260, 147], 'plain_up': [260, 147]}, 'want': [260.0, 147.0]}
ok: 2: a at 480x360: {'native': [480, 360], 'canvas': [480, 360]}
ok: 2: thirty drag events asked fewer than thirty sizes, and the last is the final one: {'setters': 3, 'last': 'debug: native resize pid=38769 wid=102458 requested=630x450 outcome=applied observed=1 actual=630x450 moved=0'}
ok: 2: the window and the canvas end where the pointer did: {'native': [630, 450], 'canvas': [630, 450]}
ok: 2: the top-left stays: {'before': [130, 185, 480, 360], 'after': [130, 185, 630, 450]}
ok: 2: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [315, 147], 'plain_up': [315, 147]}, 'want': [315.0, 147.0]}
ok: 11: a at 480x360: {'native': [480, 360], 'canvas': [480, 360]}
ok: 11: the first motion is followed: {'native': [500, 380], 'canvas': [500, 380]}
ok: 11: nothing ended the grab while the pointer rested: []
ok: 11: the next motion is taken: {'Ok': {'DebugPointer': {'screen': [1143, 904]}}}
ok: 11: and the size follows it: {'native': [540, 400], 'canvas': [540, 400]}
ok: 11: completed: ['debug: size transaction 22 of #2 ended phase=complete']
ok: 11: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [270, 147], 'plain_up': [270, 147]}, 'want': [270.0, 147.0]}
ok: 6: a at 480x360: {'native': [480, 360], 'canvas': [480, 360]}
ok: 6: N is a snap gap to the right of A: {'a': [235, 250, 480, 360], 'n': [727, 250, 420, 502]}
ok: 6: alt + shift + right is bound to resize-window-snapped: debug: pointer down button=1 trigger=right binding=resize_window_snapped window=#2
ok: 6: it carries the cluster: debug: resize grab transaction=24 window=#2 edges=right group=1 ratio=0
ok: 6: A grew by 40: {'native': [520, 360], 'canvas': [520, 360]}
ok: 6: N moved on the canvas by what A's window took: {'a': [[235, 250, 480, 360], [235, 250, 520, 360]], 'n': [[727, 250, 420, 502], [767, 250, 420, 502]]}
ok: 6: N's own window was neither resized nor moved: {'before': [968, 417, 420, 502], 'after': [968, 417, 420, 502], 'requests': []}
ok: 6 plain: resize-window carries no cluster: debug: resize grab transaction=25 window=#2 edges=right group=0 ratio=0
ok: 6 plain: A shrank by 80: {'native': [440, 360], 'canvas': [440, 360]}
ok: 6 plain: N stayed where it was: {'before': [767, 250, 420, 502], 'after': [767, 250, 420, 502]}
ok: 6: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [220, 147], 'plain_up': [220, 147]}, 'want': [220.0, 147.0]}
ok: 7: a at 480x360: {'native': [480, 360], 'canvas': [480, 360]}
ok: 7: four points right of A's frame is its resize border, right edge: {'Ok': {'DebugPointer': {'screen': [1177, 764], 'hit': None, 'border': 'right', 'clip_rect': {'origin': {'x': 693, 'y': 584}, 'size': {'width': 480, 'height': 360}}, 'screen_rect': {'origin': {'x': 693, 'y': 584}, 'size': {'width': 480, 'height': 360}}}}}
ok: 7: an unbound left press on the border starts a resize by that edge: debug: pointer down button=0 trigger=left binding=none border=right window=#2
ok: 7: by the right edge, without the cluster (decoration_resize_snapped is off): debug: resize grab transaction=27 window=#2 edges=right group=0 ratio=0
ok: 7: A grew by 30: {'native': [510, 360], 'canvas': [510, 360]}
ok: 7: the left edge stays: {'before': [215, 250, 480, 360], 'after': [215, 250, 510, 360]}
ok: 7: twelve points out is no window and no border: {'Err': 'no window takes a press at that point'}
ok: 7: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [255, 147], 'plain_up': [255, 147]}, 'want': [255.0, 147.0]}
ok: 7b: a at 480x360: {'native': [480, 360], 'canvas': [480, 360]}
ok: 7b: N is a snap gap to the right of A: {'a': [230, 250, 480, 360], 'n': [722, 250, 420, 502]}
ok: 7b: with decoration_resize_snapped the border's resize carries the cluster: debug: resize grab transaction=29 window=#2 edges=right group=1 ratio=0
ok: 7b: A grew by 30: {'native': [510, 360], 'canvas': [510, 360]}
ok: 7b: N moved by what A's window took, and its own window was left alone: {'n': [[722, 250, 420, 502], [752, 250, 420, 502]], 'native': [[968, 417, 420, 502], [968, 417, 420, 502]]}
ok: 7b: with resize_on_border off the band is no border: {'Err': 'no window takes a press at that point'}
ok: 7b: and it is one again with the default: {'Ok': {'DebugPointer': {'screen': [1222, 764], 'hit': None, 'border': 'right', 'clip_rect': {'origin': {'x': 708, 'y': 584}, 'size': {'width': 510, 'height': 360}}, 'screen_rect': {'origin': {'x': 708, 'y': 584}, 'size': {'width': 510, 'height': 360}}}}}
ok: 3: b at 300x292: {'native': [300, 292], 'canvas': [300, 292]}
ok: 3: dragged past its maximum the window ends at it: {'native': [640, 552], 'canvas': [640, 552]}
ok: 3: the top-left stays, and some request was answered clamped: {'frame': [[200, 54, 300, 292], [200, 54, 640, 552]], 'outcomes': ['applied', 'clamped', 'rejected']}
ok: 3 maximum: a click on the tile of b lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [320, 147], 'plain_up': [320, 147]}, 'want': [320.0, 147.0]}
ok: 3 minimum: the grab is the left edge's: debug: resize grab transaction=32 window=#3 edges=left group=0 ratio=0
ok: 3: dragged below its minimum the window ends at it: {'native': [300, 552], 'canvas': [300, 552]}
ok: 3 minimum: the right edge stays for the size the window took: {'before': [200, 54, 640, 552], 'after': [540, 54, 300, 552], 'want': [540, 54, 300, 552]}
ok: 3: what the adapter answered while B was dragged below its minimum: ['applied', 'clamped', 'rejected']
ok: 3 minimum: a click on the tile of b lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [150, 147], 'plain_up': [150, 147]}, 'want': [150.0, 147.0]}
ok: 4: C before: {'native': [420, 502], 'canvas': [420, 502]}
ok: 4: the canvas has the size C took: {'native': [457, 502], 'canvas': [457, 502]}
ok: 4: C ends on a whole step within one step of the 50 asked: {'start': [420, 502], 'asked': [470, 502], 'took': [457, 502]}
ok: 4: a click on the tile of c lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [228.5, 147], 'plain_up': [228.5, 147]}, 'want': [228.5, 147.0]}
ok: 5: C still holds the focus before the press on F: [8]
ok: 5: what the adapter answered for a window that cannot be resized: [('size read', 'observed'), ('resize', 'unsupported'), ('size read', 'observed')]
ok: 5: nothing was resized, on the canvas or natively: {'canvas': [[340, 99, 420, 502], [340, 99, 420, 502]], 'native': [[668, 417, 420, 502], [668, 417, 420, 502]]}
ok: 5: no size transaction is left behind: 420 502
ok: 5: a click on the tile of f lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [210, 147], 'plain_up': [210, 147]}, 'want': [210.0, 147.0]}
ok: 8: p at 400x300: {'native': [400, 300], 'canvas': [400, 300]}
ok: 8 right edge +60: the grab holds the ratio: debug: resize grab transaction=36 window=#4 edges=right group=0 ratio=1
ok: 8 right edge +60: P ends at [460, 345]: {'native': [460, 345], 'canvas': [460, 345]}
ok: 8 corner, width drives (80 * 300 >= 10 * 400): p at 400x300: {'native': [400, 300], 'canvas': [400, 300]}
ok: 8 corner, width drives (80 * 300 >= 10 * 400): the grab holds the ratio: debug: resize grab transaction=38 window=#4 edges=bottom_right group=0 ratio=1
ok: 8 corner, width drives (80 * 300 >= 10 * 400): P ends at [480, 360]: {'native': [480, 360], 'canvas': [480, 360]}
ok: 8 corner, height drives (20 * 300 < 90 * 400): p at 400x300: {'native': [400, 300], 'canvas': [400, 300]}
ok: 8 corner, height drives (20 * 300 < 90 * 400): the grab holds the ratio: debug: resize grab transaction=40 window=#4 edges=bottom_right group=0 ratio=1
ok: 8 corner, height drives (20 * 300 < 90 * 400): P ends at [520, 390]: {'native': [520, 390], 'canvas': [520, 390]}
ok: 8: a click on the tile of p lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [260, 147], 'plain_up': [260, 147]}, 'want': [260.0, 147.0]}
ok: 9: a at 480x360: {'native': [480, 360], 'canvas': [480, 360]}
ok: 9: K follows the drag: {'native': [440, 522], 'canvas': [440, 522]}
ok: 9: the closed window left the canvas: {'seconds': 0.13, 'transaction': ['debug: size transaction 42 of #5 ended phase=failed']}
ok: 9: a drag after the close is taken and asks nothing; the release answers Ok: {'drag': {'Ok': {'DebugPointer': {'screen': [948, 881.3333333333334]}}}, 'setters after the close': 0}
ok: 9: after the close: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [240, 147], 'plain_up': [240, 147]}, 'want': [240.0, 147.0]}
ok: 9: another window is sizable at once: msg resize a 500 380
ok: 9: and was resized: {'native': [500, 380], 'canvas': [500, 380]}
ok: 10: a at 480x360: {'native': [480, 360], 'canvas': [480, 360]}
ok: 10: H follows the drag: {'native': [440, 522], 'canvas': [440, 522]}
ok: 10: a drag over the hung application is taken: {'Ok': {'DebugPointer': {'screen': [978, 911.3333333333334]}}}
ok: 10: while H does not answer: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [240, 147], 'plain_up': [240, 147]}, 'want': [240.0, 147.0]}
ok: 10: H's transaction had already ended when the click on A was made: {'seconds since the hang': 0.54, 'ended': ['debug: size transaction 45 of #1 ended phase=failed']}
ok: 10: H's transaction ended: {'seconds': 0.54, 'line': 'debug: size transaction 45 of #1 ended phase=failed', 'answers': [('size read', 'observed', '1'), ('resize', 'applied', '1'), ('resize', 'applied', '1'), ('resize', 'unavailable', '0')]}
ok: 10: after H's transaction ended: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [240, 147], 'plain_up': [240, 147]}, 'want': [240.0, 147.0]}
ok: 10: the canvas has the size H's window has: {'native': [440, 522], 'canvas': [440, 522]}
ok: 10: H after it answers again: a click on the tile of h lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [220, 147], 'plain_up': [220, 147]}, 'want': [220.0, 147.0]}
ok: 10b: H follows the drag: {'native': [460, 542], 'canvas': [460, 542]}
ok: 10b: the drag that stalls H is taken: {'Ok': {'DebugPointer': {'screen': [994.6666666666666, 928]}}}
ok: 10b: while H's size request is unanswered: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [240, 147], 'plain_up': [240, 147]}, 'want': [240.0, 147.0]}
ok: 10b: H's transaction was unresolved when the click on A was made: {'unresolved before the click': True, 'and after it': True, 'seconds since the stall': 0.54}
ok: 10b: msg resize of another window meanwhile: refused as pending: error: a native resize of window 1 is still pending
ok: 10b: H's transaction ended: {'seconds': 1.08, 'line': 'debug: size transaction 46 of #1 ended phase=failed', 'answers': [('size read', 'observed', '1'), ('resize', 'applied', '1'), ('resize', 'applied', '1'), ('resize', 'readback_failed', '0'), ('size read', 'unavailable', '0')]}
ok: 10b: after H's transaction ended: a click on the tile of a lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [240, 147], 'plain_up': [240, 147]}, 'want': [240.0, 147.0]}
ok: 10b: the canvas has the size H's window took: {'native': [500, 582], 'canvas': [500, 582]}
ok: 10b: H after it answers again: a click on the tile of h lands once, within 2 points: {'delta': {'plain_down': 1, 'plain_up': 1}, 'last': {'plain_down': [250, 147], 'plain_up': [250, 147]}, 'want': [250.0, 147.0]}
ok: 12: decoy took no event, was never activated and has its bounds: {'bounds': [968, 417, 420, 502], 'activations': 0}
ok: 12: every pid acted on is in the scope: {'named': [38769, 38771, 38773, 38775, 38777, 38779, 38781, 38783], 'scope': [38769, 38771, 38773, 38775, 38777, 38779, 38781, 38783], 'decoy': 38785}
ok: 12: no press or tile was refused as unsettled: []
ok: 12: nothing said a pointer resize is gated: []
ok: 12: every resize grab's transaction ended: {'grabs': 25, 'not ended': []}
ok: 12: the one slot is free at the end: msg resize a 480 360
ok: 12: and A was resized: {'native': [480, 360], 'canvas': [480, 360]}
ok: 12: what the native adapter answered, by outcome: {'size read observed': 89, 'resize applied': 124, 'resize clamped': 4, 'resize rejected': 5, 'resize unsupported': 1, 'size read stale_identity': 1, 'resize unavailable': 1, 'resize readback_failed': 1, 'size read unavailable': 1}
ok: quit within 8 s
PASS: scoped resize drag: the nine cells, coalesced requests, a pointer at rest, minimum, maximum and increment, a window that takes no size, the snapped cluster, the resize border, preserve_aspect_ratio, a window closed and an application hung or stalled mid-grab; decoy untouched
```

The test was tightened after that run and run again on the same day (182
`ok`, the same `PASS` line; the window ids are that run's). The line
`1: the press raises and focuses A before any drag` above showed the focus
alone; the raise is now shown by what a press would hit, the press on F is
checked for its binding, and the drag after a close for its answer:

```
ok: 1: A's right side lies beneath N before the press: {'Err': 'window #5 is under that point'}
ok: 1: the press focuses A before any drag: [1]
ok: 1: and raises it: the same point is A's now: {'Ok': {'DebugPointer': {'screen': [996, 684], 'hit': 1, 'border': None, 'clip_rect': {'origin': {'x': 618, 'y': 433}, 'size': {'width': 420, 'height': 502}}, 'screen_rect': {'origin': {'x': 618, 'y': 433}, 'size': {'width': 420, 'height': 502}}}}}
ok: 5: the press is the right button's, bound to resize-window: debug: pointer down button=1 trigger=right binding=resize_window window=#8
ok: 9: a drag after the close is taken: {'Ok': {'DebugPointer': {'screen': [948, 881.3333333333334]}}}
```

What that run shows, and what it does not:

- The nine cells resize the edges upstream's grid names, the opposite edge
  stays on the canvas, and in every case each setter was answered `moved=0`
  and the fixture's own top-left was where it had been: the real window is
  not moved for a left or top drag.
- Thirty drag events with nothing between them asked three sizes, the last
  the final one (two in earlier runs of the same case).
- A window dragged past its maximum and below its minimum ended at the limit
  with the canvas at that size; the adapter answered `applied`, `clamped`
  and `rejected` on the way.
- The fixture that is not resizable answered `unsupported` to the one size
  asked, the transaction ended failed within a second of the release, and
  nothing was resized.
- A window closed under a resting grab left the canvas in 0.13 s. An
  application hung before the next size was asked refused it as
  `unavailable` and the grab ended in about half a second. An application
  that took the size and never answered (case 10b) left the transaction
  unresolved for about a second, the adapter's failed readback and one more
  read; a click on another window landed while it was unresolved, and
  `msg resize` of another window was refused as pending meanwhile.
- Not shown: a person's press or drag, the window server delivering an
  Option-right drag to the canvas panel, any application of the owner's, a
  tile with a picture during a drag, a second display, a trackpad gesture
  through the shell, a pointer that leaves the screen (the clamp is in the
  controller scenarios only), and how long a real application takes to answer
  or refuse a size.
- `tests/e2e/scoped-windows.sh` and `tests/e2e/scoped-sizing.sh` passed on the
  same build, before it.
- Controller scenarios, in which the test plays the native side:
  `cargo test -p driftwm-desktop --test gesture_flow --test native_resize_flow --test sizes_flow --test rules_flow --test pointer_flow`
  (the resize swipes, `readback_grab_*`, the ratio, the resize border), and
  `tests/e2e/desktop-resize.sh`, the headless coordinator regression, whose
  readback case now also covers a grab at rest that is held and one that is
  not.

## Upstream behaviour gaps closed

Earlier sections of this file recorded nine places where the app behaved
otherwise than DriftWM although DriftWM's behaviour can be had here. This is
what each does now. **None of it has been seen on a display or done with a
pointer**: the controller's side is covered by its scenarios, the shell's side
is built and read, and the app has been launched and driven over its socket
only ([What has been run for the closed gaps](#what-has-been-run-for-the-closed-gaps)).

| What | Before | Now |
| --- | --- | --- |
| A press bound to `move-window`, `move-snapped-windows`, `resize-window` or `resize-window-snapped` (⌥ left or right drag, with ⇧ for the cluster) | started its drag and focused nothing | raises and focuses the window under the pointer first, a screen-pinned window included, and the real window is then focused natively as after a click. A widget still refuses the drag and gets the press as a click. A resize press does this also where the resize is turned away (a detached placeholder or an application that takes no size). Since 2026-10-11 a resize press begins a resize in every normal run ([Resizing a window with the pointer](#resizing-a-window-with-the-pointer)) |
| `Infinify msg resize WIDTH HEIGHT` (the flag only) | left the stacking alone | raises the window over the other canvas windows, without giving it the focus. Asking again for the size last asked changes nothing, the stacking included, as upstream's does |
| A problem in the config file | shown in the error bar and again in the status line | shown in the error bar only; the status line keeps its own notes (bindings left out, a `--super` chord or a load the controller refuses). Every message still goes to stderr |
| Several warnings in one file | the bar named the parser's first, which for unknown actions changed from one load to the next | the bar names the first in sorted order, the same at every load, and stderr lists them in that order |
| Pick mode over a widget or a pinned window | as now, on a reading of upstream's documentation | unchanged, and now read against upstream's code: a widget and a pinned window keep their pointer below `[zoom] interact_min`; where a canvas window lies over a widget the press is that window's and the widget gets nothing |
| `fit-window`, `fit-window-snapped`, `fill-window` after a step, a `msg resize` or a fill that the window clamped (the flag only) | measured the window by the size it took | measure it by the size it was last asked for, as upstream does |
| Several windows with a rule's `size` appearing together (the flag only) | the first was asked, the others kept their size | each is asked, one after another in the order they appeared, and each is placed off the frames the earlier ones are taking, so they cascade as windows that already have the size do. One that is sized by hand, by an action or by `msg resize` while it waits is not asked afterwards |
| A rule's `size` (the flag only) | the window was placed at its own size and then asked, a widget and a rule-pinned window never | the window is placed for the size its rule names and then asked, a widget and a rule-pinned window too |
| `Infinify msg camera` printing `1950 -0` | as now | unchanged: upstream's own client prints a negative zero for a centre whose Y is 0, so nothing rewrites it |

A press bound to `resize-window` uses the normal readback path. The retired
orange-handle resize flag is no longer accepted; no replacement flag, binding
or `msg` command was added.

What still differs from DriftWM in these nine places:

- A press while a size is still owed is dropped and focuses nothing, and so
  does a move press the controller refuses. Upstream has no such refusal and
  has by then raised and focused the window. A resize press that is turned
  away under the flag is raised and focused by itself, as one without the
  flag is.
- A pick-mode press that turns into a move asks for the native focus twice,
  at the press and when the drag begins, the second request replacing the
  first. Upstream focuses once.
- `Infinify msg move X Y` still does not raise the window, where upstream
  raises a live client.
- The warning the bar names can be another than upstream's for a table the
  parser reads in a fixed order, since upstream names the parser's first.
- A ruled window that takes another size than its rule names keeps the
  top-left of the frame it was placed for, where upstream places the size it
  got. Until it answers it is on the canvas at its own size, where upstream
  shows it only once it is sized.
- Ruled windows are asked in turn, not all at once, and the opening of one
  that waits is not held back for its size until its own turn begins; one
  that appeared during a drag is asked with the next new window or at the
  end of the next size transaction.
- A resize by handle ends what a window was last asked for; upstream goes on
  measuring by the last size the drag asked.
- The fixture modes (`--demo*`, `--owned-resize-*`) send the same
  `begin_drag` and `begin_native_resize` as before, and the controller now
  also raises and logically focuses the window for them and issues a focus
  request those runs never answer, having no navigation coordinator. Whether
  that shows in a fixture run has not been tried: no fixture was run.

### What has been run for the closed gaps

Historical evidence: invocations of `--experimental-native-resize` in this
subsection refer to the mode removed on 2026-10-12.

On 2026-10-10, macOS 27.2, Apple Silicon, in this tree, which has every
earlier milestone but fullscreen:

- `./scripts/build-app.sh`: built and ad-hoc signed; nothing launched.
- `cargo fmt -p driftwm-desktop -- --check` and
  `cargo clippy -p driftwm-desktop --all-targets -- -D warnings`: clean.
- `cargo test -p driftwm-desktop` for `pointer_flow`, `sizes_flow`,
  `rules_flow`, `effects_flow`, `passthrough_flow`, `ipc_flow`,
  `navigation_actions_flow`, `gesture_flow`, `lifecycle_flow`, `config_flow`,
  `render_flow` and `controller_flow`: all 186 scenarios passed, `sizes_flow`
  with 31 and `rules_flow` with 26. They cross the exported C ABI and JSON,
  and the test plays the native side: it answers every focus request and
  every resize effect with a made-up result. They cover the raise and focus
  inside `begin_drag`, `begin_resize` and `begin_native_resize` with the
  request in the reply, the raise of an IPC resize and the identical
  request that raises nothing, the bar's message over
  two dozen loads of a file whose warnings the parser returns in more than
  one order, the pick-mode hit over a widget under a canvas window and a
  pinned widget, the fit and the fill after a clamped request, five ruled
  windows that map together and are asked in turn, the frames a rule's
  `size` is placed for, three windows of one rule that map together and
  cascade, two under `auto` placement, and a waiting window that is sized
  first (by `msg resize`, a fit, a resize drag and a handle resize) and is
  then not asked. `native_resize_flow` (25), the module of the one other
  file the review fixes touched, passed too.
- Not run: `./tests/e2e/desktop-navigation.sh`, because neither the navigation
  coordinator nor its regression changed, and `./tests/e2e/desktop-resize.sh`,
  whose regression reads only the transaction id of a `begin_native_resize`
  reply and so was left alone; no fixture, probe or demo mode.
- Four launches of the built app as `--windowed 1100x700` on a private scene
  (three detached placeholders: "Notes" 640x420, "Browser" 900x600, "Terminal"
  560x380), a private config whose `[keybindings]` names two unknown actions,
  and a private socket, driven by a script through `Infinify msg`, 5, 6, 3
  and, after the review fixes and on the final build, 6 seconds long. None
  had Screen Recording access (stderr said `Windows are
  not managed: …`), so no window had an application behind it. Each ended on
  SIGTERM with exit status 0 and its socket removed. Observed:
  - `camera` read `550 -318` at launch and after a first `action
    home-toggle`, which does nothing there because the origin is already in
    view; `action center-nearest right`: `1950 -0`; `action pan-viewport
    right`: `2050 -0`; `action home-toggle`: `0 -0`. `--json state` has the
    same centre as `[0.0, -0.0]`. The negative zero is upstream's and is
    left. The fourth run read `550 -318`, `1950 -0` after `center-nearest
    right`, `-620 -890` after `focus --id 3` and `0 -0` after `home-toggle`;
  - `resize --id 1`: `640 420`; `resize --id 1 800 500`: `error: resize is
    not implemented on macOS yet: native layout resize is not available`,
    exit 1, and the size read `640 420` again. The runs had no
    `--experimental-native-resize`, so the raise of an accepted resize was
    not reached;
  - `screenshot -o FILE`: a 1100x636 PNG of the dot grid with the corner of
    the "Notes" placeholder at (750, 468), where its frame at world (200,
    150) falls in a view centred on the origin. The capture has no error bar
    by design;
  - the two config warnings on stderr at launch and after each `action
    reload-config`, and no other line for them. In the first run, built
    before stderr was sorted, the two lines changed places between loads
    (alpha then zeta at launch, zeta then alpha after the first reload, alpha
    then zeta after the second and third). In the second run, and in a third
    of twelve reloads, every load printed them in the same order, thirteen
    times out of thirteen in the third, and four out of four in the fourth.
- Not done in any run: no press, drag, scroll or gesture was made, no key was
  pressed, nothing was looked at in the panel, so the focus a bound press
  takes, a resize press that is turned away included, the status line
  without the config message and the error bar with
  its one line are compiled and read only; the bar's text is not readable
  over the socket. No window had a live source and the flag was off, so no
  size was asked: the raise of `msg resize`, the fit after a clamped request,
  a rule's `size` placed for and asked in turn, the cascade of ruled windows
  that appear together, a waiting window sized first, and the shell taking a
  waiting window's transaction for a sizing one have the controller scenarios
  and nothing else.

## Fullscreen

DriftWM's fullscreen, as controller policy: one window takes its whole display
on the canvas, alone, and everything is put back when it leaves. The rules are
upstream's and are set out in the
[fullscreen contract](../../crates/desktop/FULLSCREEN.md). This is **not**
macOS's own fullscreen: that moves a window to another Space, out of the
canvas, and is never used. The window stays an ordinary window and is asked
for the size of its display's canvas view.

Asking a real window for a size goes the way the
[sizing actions](#window-sizing-actions) go, and like them fullscreen runs in
every normal run with no flag since 2026-10-11.

- **Size asked:** the size of the display's canvas view: the whole display in
  a normal run, the panel in `--windowed`.
- **Position asked:** none. Nothing sets a native position. On the canvas the
  window is drawn in its display's screen space, at the corner when it has the
  display's size and in the middle when its application granted less.
- **On leaving:** the window's place, its pin, the camera and the zoom come
  back at once, and its size from before is asked of it. At quit every
  fullscreen is ended first, so no window keeps the display's size.
- **Unlike macOS full screen:** no separate Space, no transition, no
  `AXFullScreen`. The window keeps its title bar and stays an ordinary window
  on the same Space; the menu bar and the Dock are not hidden by it.

**What has been made fullscreen:** fixture windows of the test's own and an
Electron window, in a windowed run of 1100x700
([What has been run for sizing without the flag](#what-has-been-run-for-sizing-without-the-flag),
cases 12, 13, 17, 20 and 22). No application of the owner's, no whole display,
and nothing was seen: the test bed has no Screen Recording access.
[What has been run for fullscreen](#what-has-been-run-for-fullscreen) has the
earlier, headless detail.

### What turns it on

| Launch | What happens |
| --- | --- |
| default | `toggle-fullscreen` runs, a rule's `fullscreen = true` is applied to a new window, and ⌃⌥F is registered as a global hot key while a canvas panel is open (never in `--windowed`). |

There is no other switch and no config key for it. The fixture modes
(`--demo*`, `--owned-resize-*`) get none of it: there `toggle-fullscreen`
answers `action not implemented on macOS yet: toggle-fullscreen`.

| Control | What it does |
| --- | --- |
| ⌃⌥F (`mod+f`); ⌃⌥ middle click on a window (`mod+middle`); ⌥ with a three-finger pinch in or out on a window; `Infinify msg action toggle-fullscreen`; a hot corner or any other binding of `toggle-fullscreen` | If the focused window is fullscreen, on any display, it leaves. Else if the active display has a fullscreen window, that one leaves. Else the focused window enters, on the display its rule's `output` names, else the display it is pinned to, else the active one. With a widget or a detached placeholder focused nothing is entered and nothing is said, as upstream. |
| `[[window_rules]] fullscreen = true`, with or without `output` | A new window that matches enters fullscreen once it is placed, taking the display from whoever was fullscreen there, and is focused whatever `focus_on_open` says. With a rule `size` beside it the window is placed for that size, as upstream places it, enters at the size it has, and is asked for the rule's size only when it leaves: that frame is where it comes back to. |

Entering saves the window's place and size, its display's camera and zoom and
its pin; parks that display at its camera in whole points at 1:1; focuses the
window; and asks it for the display's whole canvas view. Leaving puts the
place, the pin, the camera and the zoom back at once and asks the window for
its old size. A fit or a fill survives a fullscreen.

### What a fullscreen display shows

- The fullscreen window and nothing else: no other window, no widget, no
  screen-pinned window. It is drawn bare (no border, no rounded corners, no
  shadow, no title bar of the canvas's), at 1:1 from the display's corner
  whatever the camera and zoom were.
- Black behind it. A window that took a smaller size than the display sits in
  the middle with black bands; one that took more starts at the corner and is
  cut off by the display.
- The translucent case, upstream's: when the window's rule `opacity`, or
  `msg opacity`, is below 1, the canvas background and the outlines of the
  other displays keep drawing behind it. No other window does.
- No orange resize handles on it, and its display's hot corners do not fire
  unless that display's `disable_when_fullscreen` is `false`.
- Frost only by the window's own rule: a rule's `blur = true` frosts what is
  behind a fullscreen window as behind any other, `[decorations] blur` does
  not reach one (upstream's `effective_blur`). The controller decides; the
  renderer draws the flag it is given.
- The error bar, as on every display: a config problem is shown across the
  bottom of a fullscreen display too, above the window. Upstream builds the
  bar for every output and gates it on nothing, and the compositor notes say
  the same (COMPOSITOR-NOTES.md 18.5).
- No closing snapshot and no stand-in fade: a window that closes behind the
  fullscreen one, or a placeholder that is dismissed or adopted there, fades
  on the other displays and not on this one, as upstream draws "no
  dying-window flash over a fullscreen app". An animation that was running
  when the display became fullscreen runs out unseen; what is left of it is
  drawn again if the fullscreen ends first.
- The fullscreen window itself opens and closes like any other. One that a
  rule makes fullscreen as it appears plays its open animation from its
  first picture, at the size it has: it is not held back until the display's
  size has arrived, as a window waiting for a rule's `size` is, because the
  display is already black and showing nothing else. One that closes while
  fullscreen leaves its snapshot baked bare, as it was drawn, which fades
  from the display's rectangle over the canvas that is back by then.
- Other displays keep their canvas, and none of them draws the fullscreen
  window, whatever canvas its camera shows. They stop drawing the outline of
  the fullscreen display's viewport: it shows a window, not a part of the
  canvas, and upstream projects no outline for it. That last part is compiled
  and read only; no second display was available.
- The pointer reaches the fullscreen window where it is drawn and nothing
  else on that display. Clicks and motion are forwarded to the application by
  the same path as for any window; the shell computes no mapping of its own.
  With `focus_follows_mouse`, moving onto that display gives the fullscreen
  window the focus back.
- `msg state` lists it under `fullscreen` with its display, not under
  `windows`. `msg move`, `msg resize` and `msg pin` on it are refused in
  upstream's words, and a refused `msg resize` does not raise it. ⌥Tab
  passes over it.
- Its rule's `pass_keys` and `pass_mouse` hold
  ([Passing keys and presses](#passing-keys-and-presses-to-an-application)):
  while it holds the keyboard its passed chords are not Infinify's, and a
  press, a scroll or a wheel notch over it that its rule claims goes to the
  application and ends nothing. Upstream asks a fullscreen window's claims
  with no pick-mode gate, and so does the lookup.
- A screen-pinned window cannot be dragged onto it: while the pointer is over
  a fullscreen display the drag stands still, the window staying on the
  display it was on, and goes on when the pointer leaves again, as
  upstream's move grab freezes there. A pinned window of the fullscreen
  display itself is hidden with everything else and can be taken again once
  the fullscreen has ended.
- A new window that opens meanwhile is placed in the background, beside the
  place the fullscreen window comes back to, and the canvas asks for no focus
  and moves no camera. It stays there only if macOS did not give it the
  keyboard. A window that opens with the keyboard, as one the user just asked
  for usually does, is followed like any other native focus change (with
  Accessibility access, at the first poll after the window is adopted): that
  ends
  the fullscreen, and the new window is focused beside the restored one.
  Upstream keeps the fullscreen in both cases.

### What ends it

Upstream's list. The display gets its camera and zoom back and the window its
place, then its size:

- `toggle-fullscreen` again.
- Any action except `toggle-fullscreen`, `spawn`, `reload-config`,
  `switch-layout`, `toggle-cursor-pan`, `set-trackpad` and `send-to-output`:
  the action then runs on the restored canvas. `exec`, `exec-terminal` and
  `exec-launcher` do end it; `spawn` does not, though the window the spawned
  application opens then can, by taking the keyboard. `send-to-output` moves
  the fullscreen to the adjacent display instead.
- A bound pan or zoom of that display (⌃⌥-drag, ⌃⌥-scroll, a pan or zoom
  gesture), and a bound drag or resize of the window. A drag or resize press
  ends the fullscreen first, then raises and focuses the window, then takes
  hold of it, upstream's order. A wheel notch bound to an action runs that
  action like a key, so it ends the fullscreen exactly when the key would.
  A press or scroll the fullscreen window's `pass_mouse` claims is the
  application's and ends nothing.
- `msg camera` and `msg zoom` writes and `msg suspend`. `msg close` ends
  none: it only presses the window's close button or dismisses a
  placeholder, as upstream's does. Asked of the fullscreen window itself, the
  fullscreen ends when that window is gone.
- Another window of the canvas taking the keyboard by itself on that display
  (Command-Tab, the Dock, a click in the real window, a new window that
  takes the keyboard as it opens).
- The window closing, or becoming a placeholder; another window whose rule
  says `fullscreen` taking the display; the display being disconnected.

`home-toggle` (⌃⌥A) pressed out of fullscreen and away from home remembers
the window: pressed again at home, the view is put back and the window is
fullscreen again, as upstream.

A sizing action pressed during a fullscreen ends it and then acts on the
window as it was before, in one resize: from the display's size straight to
the fit, the fill or the step.

### What changes with fullscreen

In every normal run (an isolated controller that is told nothing still
answers byte for byte as before, which a controller test compares against
replies captured from the earlier tree):

- ⌃⌥F is taken from every application while a canvas panel is open. Unbind it
  in the config file (`"mod+f" = "none"`) to give it back.
- ⌃⌥ middle click and ⌥ with a three-finger pinch on a window now ask that
  real window to change size, where they showed a not-implemented note.
- A config whose window rule says `fullscreen = true` now makes a matching
  new window fullscreen; before, it was only
  recorded.
- Hot corners stop firing on a display that has a fullscreen window.

### Limits of fullscreen

- **Run on fixture windows in a 1100x700 panel only.** No application of the
  owner's has been made fullscreen, no window has been asked for a whole
  display, and nothing has been seen in the app's own panel.
- The size asked for is the display's whole rectangle, the area under the menu
  bar and the Dock included, since the output is the whole display. macOS
  grants the visible area at most, and only from that area's corner: the real
  window is moved there first ([Limits of sizing](#limits-of-sizing)) and
  takes the visible area's size, which the size transaction handles as a
  clamped size (cases 13 and 19 of the sizing test): fullscreen at the size it
  took, centred. Leaving fullscreen gives the size back and leaves the real
  window at that corner. Not seen on a whole display: the test's panel is
  1100x700.
- No transition. Upstream grows the window in and holds the picture on the
  way out; here the display shows the window alone from the moment it is
  asked. Under the flag its picture is the grey placeholder while a size
  change is unresolved; without it the picture is whatever the stream has.
- A window whose application refuses or clamps the size stays fullscreen at
  the size it has, centred; one the adapter cannot resize at all is asked
  nothing from its second fullscreen on. A size change back that ended
  before the window was asked (Escape, a display change, an adapter that was
  not available) is begun again with the next key, click, gesture or `msg`
  request, three times in all; after that, and after a size change back the
  application refused, the window is on the canvas at the size it has.
- **After some exits the old size comes late.** A fullscreen ended by a bound
  pan, a bound zoom, a pointer drag of the window, a display change or
  another window's rule taking the display puts the window and the view back
  at once, but the request for the old size is sent with the next key, click,
  trackpad gesture or `msg` request. Moving the pointer is not enough. Until
  then the window is on the canvas at the display's size.
- A resize drag begun on a fullscreen window (⌥ right drag) ends the
  fullscreen and resizes the window from the display's size: the old size is
  not asked back first, where upstream restores it and resizes from there.
- One size change at a time. `toggle-fullscreen` while another window's size
  is still on its way answers `a native resize of window N is still pending`,
  and a rule's `fullscreen` that finds one pending is not applied. Leaving is
  never refused, and leaving while the enter is still on its way turns that
  same request around.
- Quit while a window is fullscreen: applications
  outlive Infinify, so before anything is shut down the shell ends each
  fullscreen (`-endFullscreens`: `toggle-fullscreen` on a display the
  snapshot reports fullscreen, one at a time, then one `msg state`-like
  request that carries a size still owed) and lets each size change back run
  to its end, for three seconds at most. The `quit` action ends the active
  display's fullscreen itself, and Quit no longer cancels that size change.
  The scene saved then has the cameras and frames from before. **Addressed,
  and not run on a real window**: in the app it ran only with nothing
  fullscreen, where it does nothing. When it is cut off (a crash, a kill, an
  application that does not answer in three seconds, a size the application
  clamps) the real window keeps the size it has, and the scene is saved to
  match: the window's old place at that size, so the next launch adopts it
  as a window of the display's size and can resize it. Its size from before
  the fullscreen is then lost.
- Beside a fullscreen window smaller than its display, a press or scroll on
  the black band is looked up as empty canvas, where upstream treats the whole
  display as the window, and an unbound click there does not give the window
  its focus back. The window's `pass_mouse` claims nothing there either,
  where upstream's still does.
- While a fullscreen's size change is on its way, a new window whose rule
  names a `size` waits for it like behind any other size change, and is
  asked when it ends.
- `msg screenshot` captures the canvas, not the panel: by reading the code,
  during a fullscreen it draws every canvas window at its world place, the
  fullscreen one bare, over the background, where the panel shows the
  fullscreen window alone over black. No capture was made during a fullscreen
  in the app.
- No pointer warp on enter or exit, no carried pointer lock, and an
  application's own request to go fullscreen is not this and is not followed.
- A window that was already open when the app started, one attached from the
  chooser and one that takes over a saved slot are never made fullscreen by a
  rule.
- The shell suppresses a hot corner on a fullscreen display from the last
  snapshot it drew, so it can be one draw behind the controller, which
  applies the same rule itself.

### What has been run for fullscreen

Historical evidence: invocations of `--experimental-native-resize` in this
subsection refer to the mode removed on 2026-10-12.

On 2026-10-10, macOS 27.2, Apple Silicon, in one tree with every milestone up
to window sizing:

- `./scripts/build-app.sh`: built and ad-hoc signed; nothing launched.
- `cargo fmt -p driftwm-desktop -- --check` and
  `cargo clippy -p driftwm-desktop --all-targets -- -D warnings`: clean.
- `cargo test -p driftwm-desktop` for `fullscreen_flow`, `sizes_flow`,
  `native_resize_flow`, `rules_flow`, `render_flow`, `pointer_flow`,
  `lifecycle_flow`, `navigation_actions_flow`, `platform_actions_flow`,
  `ipc_flow`, `config_flow` and `controller_flow`, and then `gesture_flow`,
  `motion_flow`, `view_actions_flow`, `navigation_flow` and
  `focus_cycle_flow`, whose source files this work also touched: all 229
  scenarios passed, `fullscreen_flow` with 15. They cross the exported C ABI
  and JSON on two displays, neither at the global origin; the test answers
  every resize effect with a made-up native result.
- `./tests/e2e/desktop-navigation.sh`: PASS. It runs the navigation
  coordinator headless against the Rust library; that coordinator is
  unchanged, and the script does not go through the shell's reply hook.
- A throwaway program against the controller library, outside the
  repository, read upstream's built-in default tables: 45 key bindings, of
  which 42 run without the capability (all but ⌃⌥F, ⌃⌥M and ⌃⌥⇧M) and all 45
  with it; of the 35 action names of upstream's grammar six are refused by
  name without it (`grow-window`, `shrink-window`, `toggle-fullscreen`,
  `fit-window`, `fit-window-snapped`, `fill-window`) and none with it.
- The renderer, before the controller side existed: a throwaway program
  outside the repository drove `DWCanvasRenderer` offscreen at 2x with
  hand-written snapshots in the contract's shape and read the frames back. A
  fullscreen window of the display's size covered the frame bare, with no
  background, outline or other element; a 700x500 one on a 900x600 display
  reported at zoom 0.6 landed on exact device pixels in the middle with
  opaque black bands; with the `canvas` backdrop and opacity 0.5 the bands
  were pixel for pixel the display with no window; and leaving restored the
  frame byte for byte. The same under the address and undefined-behaviour
  sanitizers. A second one fed `DWHotCorners` hand-written entries: 9 of 9
  cases, among them that a suppressed entry is still latched. Neither program
  is in the repository, and neither used a snapshot the controller produced.
- Two launches of the built app as `--windowed 1100x700` on a private scene
  (three seeded detached placeholders, 640x420 at (200, 150), 900x600 at
  (1500, -300) and 560x380 at (-900, 700)), a private config (a `*` output
  with `disable_when_fullscreen = false` and no corner bound, and a window
  rule with `fullscreen = true`, `output = "windowed"` and `opacity = 0.8`
  that no placeholder can match) and a private socket, driven by a script
  through `Infinify msg`. Neither had Screen Recording access, so no real
  window was on the canvas. The config loaded without a message. Nothing from
  them is saved as evidence.

  Without the flag (2 seconds):

  ```
  $ msg action toggle-fullscreen
  error: action not implemented on macOS yet: toggle-fullscreen
  $ msg focus --id 1
  #1 org.example.seed
  $ msg action toggle-fullscreen
  error: action not implemented on macOS yet: toggle-fullscreen
  $ msg state
  camera 550 -318
  zoom 1
  layout British (en)
  windows 3
    * #1 org.example.seed [520, -360] 640x420  "Notes"
      #2 org.example.seed [1950, 0] 900x600  "Browser"
      #3 org.example.seed [-620, -890] 560x380  "Terminal"
  fullscreen 0
  pinned 0
  layers 0
  canvas-layers 0
  outputs 1
    * windowed camera 550 -318 zoom 1 1100x636
  ```

  With `--experimental-native-resize` (1 second), the same requests on the
  same placeholders:

  ```
  $ msg action toggle-fullscreen
  ok
  $ msg focus --id 1
  #1 org.example.seed
  $ msg action toggle-fullscreen
  ok
  ```

  Both `ok` answers changed nothing: `msg state` afterwards was the block
  above line for line, `fullscreen 0` included, and `msg --json state` had
  `"fullscreen": []` and `"mode": "Normal"` for all three windows. **There is
  no refusal for a placeholder**: upstream's `toggle-fullscreen` does nothing
  without a client to act on and says nothing, and so does this. That the
  answer differs from the unflagged run shows the app told the controller it
  can resize. `msg screenshot` of the viewport wrote a 1100 x 636 PNG in both
  launches, byte for byte the same, opened and looked at: the dot grid and
  the Notes placeholder as a dark rounded tile with its bundle identifier and
  a close mark. Both apps exited with status 0 on SIGTERM and removed their
  socket.

After a review, the same day: the fixes listed in the
[fullscreen contract](../../crates/desktop/FULLSCREEN.md#after-review-2026-10-10)
went in, two of them in the shell (`-endFullscreens` before the shutdown in
`-cleanup`, with Quit no longer cancelling a size change of the controller's
own; and no viewport outline for a fullscreen neighbour, inside the
renderer's fullscreen function). `./scripts/build-app.sh` built them, the
format check and clippy were clean, and thirteen controller test modules
passed (189 scenarios, `fullscreen_flow` still 15, each extended).
`./tests/e2e/desktop-navigation.sh` was not run again: the navigation
coordinator is unchanged. The two launches were repeated on a freshly seeded
scene of the same three placeholders, with a private config (a `*` output
with `disable_when_fullscreen = false`, and a `fullscreen = true` rule that
matches none of them) and the private socket:

- without the flag, `msg action toggle-fullscreen` answered `error: action
  not implemented on macOS yet: toggle-fullscreen` before and after `msg
  focus --id 1`, and `msg state` was the block above line for line,
  `fullscreen 0` included;
- with `--experimental-native-resize`, `msg state` answered the same block,
  `msg focus --id 1` answered `#1 org.example.seed`, `msg action
  toggle-fullscreen` answered `ok` and changed nothing (`fullscreen 0`,
  `"mode": "Normal"`): a placeholder still gets no refusal;
- `msg screenshot -o` wrote the same 18 463 bytes in both, opened and looked
  at: the dot grid and the Notes placeholder as a dark rounded tile with
  `org.example.seed` and a close mark;
- both exited with status 0 on SIGTERM and removed the socket. The flagged
  one went through `-endFullscreens` on its way out, with nothing fullscreen
  and nothing owed, which is the branch that does nothing. Nothing is saved
  as evidence.

**No live window existed in any launch, so no fullscreen was entered and no
size transaction ran in the app.** The shell's side of this section is
compiled and read, and its renderer part run offscreen on hand-written
snapshots: nothing drew a controller-reported fullscreen placement, the hook
handed nothing to the resize coordinator, and no native window was read or
resized. Also unrun: ⌃⌥F and every other key, mouse binding, gesture and hot
corner that toggles fullscreen, a rule's `fullscreen` on a real window, every
way out listed above, the suppression of hot corners and of the resize
handles in the app, input forwarded to a fullscreen window, quitting or
returning to the desktop during one (the shell then ends it first: compiled
and read), a new window opening during one, `tests/e2e/desktop-resize.sh`,
and more than one display, so also the outline a fullscreen display no
longer projects.

### What has been run for fullscreen with everything else built in

Historical evidence: invocations of `--experimental-native-resize` in this
subsection refer to the mode removed on 2026-10-12.

Fullscreen was written on a tree that ended at window sizing. On 2026-10-10
(macOS 27.2, Apple Silicon) it was merged into this one, which also has the
effects, the pass rules and the pinned drag, and the closed upstream gaps.
What the shell does differently for it is in
[What a fullscreen display shows](#what-a-fullscreen-display-shows) and
[What ends it](#what-ends-it); the controller's side is in the
[fullscreen contract](../../crates/desktop/FULLSCREEN.md#merged-with-effects-pass-through-and-the-polish-pass-2026-10-10).
In the shell's own files:

- `canvas-renderer.m`: the one fullscreen function runs at the end of the
  frame the effects build, after the opening and adopted-fade bookkeeping. A
  display the snapshot reports fullscreen gets no closing snapshot and no
  stand-in fade in its frame; they stay on their own clock and are dropped
  when they are over. A placement marked fullscreen is not held for an owed
  size, in `-render:` and in `-contentChanged:`. The error bar is left as it
  is on every display. A fullscreen window that closes is baked from the
  element the fullscreen function made bare, at the display's backing scale.
- `main.m`: `-resizeCall:` is the rule-size version, which takes the
  transaction a result reply chains to for the controller's own whichever
  transaction the result was for; the fullscreen case, an exit on the
  transaction its enter began, keeps the same transaction and needs nothing
  there. `-endFullscreens` is called once, in `-cleanup`, after the hot keys,
  the config watch, the trackpad and the hover are stopped and before the
  resize coordinator is shut down, the scene saved and the compositor reset.
  Quit, SIGTERM and Return to desktop all end in `-cleanup`, which runs once.
  A screen change does not: it removes and registers the outputs again, and
  the controller keeps a fullscreen whose display is still there and ends
  one whose display is gone (`outputs_settled`), so nothing is ended for it
  by the shell.
- `scripts/build-app.sh` compiles the same files as before: no file was
  added.

Run in this tree:

- `./scripts/build-app.sh`: built and ad-hoc signed; nothing launched.
- `cargo fmt -p driftwm-desktop -- --check` and
  `cargo clippy -p driftwm-desktop --all-targets -- -D warnings`: clean.
- `cargo test -p driftwm-desktop` for `fullscreen_flow`, `sizes_flow`,
  `native_resize_flow`, `passthrough_flow`, `effects_flow`, `pointer_flow`,
  `rules_flow`, `render_flow`, `gesture_flow`, `motion_flow`,
  `navigation_actions_flow`, `platform_actions_flow`, `lifecycle_flow`,
  `config_flow`, `ipc_flow`, `view_actions_flow`, `controller_flow`,
  `navigation_flow` and `focus_cycle_flow`: all 263 scenarios passed,
  `fullscreen_flow` with 20, five of them new: a fullscreen window's
  `pass_mouse` claims and `pass_keys`, the order of a grab, a pinned drag
  beside a fullscreen display, the frost and the open and close events, and
  a ruled size that waits out an enter. The test plays the native side.
- `./tests/e2e/desktop-navigation.sh`: PASS.
- The replies of an app without the flag were captured again from the tree
  before the merge, built apart: byte for byte the ones recorded, but a key
  binding's entry in the bindings table, which has `passable` since the pass
  rules. A throwaway test against the merged controller, deleted again, read
  upstream's built-in default tables: 45 key bindings, 42 of which run
  without the capability (all but ⌃⌥F, ⌃⌥M and ⌃⌥⇧M) and all 45 with it; of
  the 35 action names of upstream's grammar six are refused by name without
  it and none with it.
- Two launches of the built app as `--windowed 1100x700` on a freshly seeded
  private scene (the three detached placeholders above), a private config (a
  `*` output with `disable_when_fullscreen = false`, and one window rule
  with `fullscreen = true`, `size`, `output = "windowed"`, both pass lists
  and `blur`, which matches no placeholder) and a private socket, driven by
  a script through `Infinify msg`. Neither had Screen Recording access. The
  config loaded without a message. Nothing from them is saved as evidence.

  Without the flag:

  ```
  $ msg state
  camera 550 -318
  zoom 1
  layout British (en)
  windows 3
      #1 org.example.seed [520, -360] 640x420  "Notes"
      #2 org.example.seed [1950, 0] 900x600  "Browser"
      #3 org.example.seed [-620, -890] 560x380  "Terminal"
  fullscreen 0
  pinned 0
  layers 0
  canvas-layers 0
  outputs 1
    * windowed camera 550 -318 zoom 1 1100x636
  $ msg action "center-nearest right"
  ok
  $ msg camera        (polled until it stopped changing)
  1950 -0
  $ msg focus
  #2 org.example.seed
  $ msg action "pan-viewport right"
  ok
  $ msg camera
  2050 -0
  $ msg action zoom-to-fit
  ok
  $ msg zoom
  0.28484848484848485
  $ msg camera
  750 -390
  $ msg action zoom-to-fit
  ok
  $ msg zoom
  1
  $ msg camera
  2050 -0
  $ msg action toggle-fullscreen
  error: action not implemented on macOS yet: toggle-fullscreen
  $ msg focus --id 1
  #1 org.example.seed
  $ msg action toggle-fullscreen
  error: action not implemented on macOS yet: toggle-fullscreen
  ```

  `msg state` then printed `fullscreen 0`, with the camera on its way to the
  Notes placeholder, and `msg screenshot -o` wrote a 1100 x 636 PNG that was
  opened and looked at: the dot grid with the Notes and Browser placeholders
  as dark rounded tiles at its edges.

  With `--experimental-native-resize`, on the same seeded scene:

  ```
  $ msg state
  (the first block above, line for line)
  $ msg action toggle-fullscreen
  ok
  $ msg focus --id 1
  #1 org.example.seed
  $ msg action toggle-fullscreen
  ok
  $ msg action fit-window
  ok
  $ msg resize --id 1 700 500
  error: this window has no native size to set: it is a stand-in or has no live window
  ```

  Both `ok` answers to `toggle-fullscreen` changed nothing: `msg state` was
  the first block again with `* #1` focused and `fullscreen 0`, and `msg
  --json state` had `"fullscreen": []` and `"mode": "Normal"` for all three.
  A placeholder still gets no refusal from `toggle-fullscreen`: the one
  refusal a stand-in gets under the flag is a sizing one, as `resize` shows.
  `msg screenshot -o` wrote 18 463 bytes, opened and looked at: the dot grid
  and the Notes placeholder as a dark rounded tile with `org.example.seed`
  and a close mark.
- Both apps exited with status 0 on SIGTERM and removed their socket. The
  flagged one went through `-endFullscreens` on its way out, with nothing
  fullscreen and nothing owed, the branch that does nothing.

**No live window existed in either launch, so no fullscreen was entered and
no size transaction ran in the app.** Nothing drew a fullscreen placement,
with or without a frost, an error bar, a snapshot or an opening window; no
key, press, scroll, gesture or drag was sent; no window had a rule, a pin or
a picture. What the merge changed in the renderer and in `main.m` is
compiled and read, and the list of what is unrun at the end of the section
above stands whole, with these added: the error bar over a fullscreen
window, a close or a dismissal behind one, a window that opens fullscreen, a
fullscreen window's pass rules, and a pinned window dragged toward a
fullscreen display.

## Experimental native resizing

Historical evidence only: this mode and its executable UI-driving probe were
removed on 2026-10-12. The following commands and descriptions record the old
implementation; they are not current launch instructions. The source is
recoverable from commit `42d17f4`, and frozen evidence remains unchanged.
None of the recorded live attempts established completed native resize and
independent pixel validation. Current owned runtime scenarios use
`tests/e2e/physical-resize-edge.sh`, `tests/e2e/scoped-resize-drag.sh` and
`tests/e2e/scoped-sizing.sh`. The standalone capture-metadata regression and
read-only saved-byte oracle remain available.

`--experimental-native-resize` enables eight orange handles on the
selected ordinary source, and that is all it is for since 2026-10-11:
DriftWM's [sizing actions](#window-sizing-actions), `msg resize`, a rule's
size, [fullscreen](#fullscreen) and
[resizing by pointer](#resizing-a-window-with-the-pointer) run without it,
settled by reading the window's size back. The flag and its handles are
legacy: they are kept as they were, they are not the way forward, and they
were not run for this change. Under the flag they run the same transaction in the
capture-acknowledged mode described here, in which a window shows a picture
and takes input only once a capture of it at its size has been acknowledged;
on the owner's real windows none ever was, so the flag is for work on the
handles, not for use. Everything below this line describes that mode. Handles use true projected world edges; viewport clipping
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

**The first run on real windows (2026-10-10) left every tile inert.** Six
adopted windows of four applications were each drawn as an empty grey tile, and
a click on any of them was refused with `source presentation unsettled`: no
capture was acknowledged for any of them. Which of the checks above refused
them is not known, because nothing said. So a refusal now says why, and the
gate itself is unchanged: a window still shows no picture, and takes no input,
that was not acknowledged against its observed geometry.

- One line on stderr per window per change of reason, once the reason has
  stood for half a second:
  `capture of #7 (com.google.Chrome) not acknowledged: REASON — DETAIL`.
  The reasons: `family`, the window is not alone in its native family or the
  family could not be read (the detail is the family query's own account,
  `no root-only extent: 3 native windows in its family (the window and 2
  attached to it)`, or its error); `geometry`, the window's extent is not
  the observed rectangle (both printed); `metadata`, the frame's own
  description failed a check (the first one that failed and its values: the
  frame status, its display time against the cutoff, the scale factors, its
  screen rectangle against the extent, its content rectangle against the
  extent and the buffer); `stale frame`, the last frame offered was displayed
  before the cutoff, by how many milliseconds; `refused`, the controller did
  not take the acknowledgement; `not installed`; `stream`, the capture stream
  failed, with its error, which nothing reported before; `unobserved`, a
  resize left the geometry unknown; and `no frame`, none was offered in two
  seconds.
- A press on such a window puts the short reason in the status line:
  `Window 7 has no picture yet and takes no input: capture not acknowledged
  (family)`.
- One comparison was wrong and is fixed. A resize result is accepted when its
  Accessibility and WindowServer rectangles agree within one point, and the
  Accessibility one is kept; the coordinator then demanded exact equality
  with the WindowServer's extent, so a window whose two rectangles differ by
  a fraction could show no picture while it was being resized. Within one
  point is now the same geometry while that window's resize transaction is
  unresolved; at rest the comparison is exact as before. This is not what
  refused the six windows: a newly adopted window's observed rectangle is the
  WindowServer's too.

What reading suggests, and the next run's stderr decides: a window with any
attached child window is refused as `family` by design, which may be most real
application windows; a still window is sent one frame per configuration
request, so a first frame refused for any reason may be the only one; and the
frame's screen rectangle has to equal the window's extent exactly. Until a run
has shown these lines, the flag is not usable on real windows: start without
it to see and click them.

`tests/e2e/desktop-resize.sh` exercises the production coordinator, Rust C ABI, and
real synthetic CVPixelBuffer/CMSampleBuffer objects without NSApplication startup or
any native windows, AX calls, capture streams, activation, event taps, or fixtures.
This is headless contract evidence only. The signed app is built without launching.
The existing independent resize fixture does **not** prove this integration. A future
explicitly authorized owned-fixture gate must cross real handles, AX mutation, SCK,
renderer pixels, independent AX/CG observation, clamp behavior, static-frame refresh,
Escape handling, and cleanup. No such integrated live proof has been run or claimed.

## Historical noninteractive owned resize gate — retired

The executable harness described below was removed on 2026-10-12. Its attempted
contracts and immutable receipts are retained as history. The current
`tests/e2e/desktop-native-resize.sh` runs build/headless metadata checks and
the offline saved-byte oracle; it has no live-owned-fixture dispatch.

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
