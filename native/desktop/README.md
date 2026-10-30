# Infinify native desktop shell

The Objective-C shell of Infinify, the macOS port of DriftWM: the canvas panels, window capture, input routing and run lifecycle around the Rust controller in `crates/desktop` (which uses `crates/core` and `crates/canvas`). A normal run is the desktop: it replaces the native one ([Desktop mode](#desktop-mode)).

The parity contract, [docs/parity/README.md](../../docs/parity/README.md), keeps what this file describes at `implemented_unverified` or below, and says what is still open. Nothing in this file is `verified`.

Related documents:

| Document | What it holds |
| --- | --- |
| [COMPOSITOR-MODE.md](COMPOSITOR-MODE.md) | The Dock-helper compositor mode: design and known limits |
| [NATIVE-DRAG-ROUTING.md](NATIVE-DRAG-ROUTING.md) | Why a captured picture cannot receive a drag, and what compositor mode does with drags between windows |
| [COMPOSITOR-NOTES.md](COMPOSITOR-NOTES.md), [BACKGROUND-NOTES.md](BACKGROUND-NOTES.md) | The Metal compositor and the canvas background renderer |
| `crates/desktop/*.md` | The controller's contract for each area (configuration, navigation, sizes, fullscreen, gestures, motion, IPC, rules, effects, lifecycle); [CONFIG.md](../../crates/desktop/CONFIG.md) is the configuration reference |
| [native/privileged/README.md](../privileged/README.md) | The Dock helper, its launch daemon and its recovery |

### File map

Each file's header says what it is and, for adapted code, which upstream file, repository and commit it comes from.

| Files | Role |
| --- | --- |
| `main.m` | The shell: canvas panels, window capture, input routing, run lifecycle, command line |
| `compositor.m`, `canvas-renderer.m`, `background.m`, `background-tiff.m`, `mac-wallpaper-cache.m`, `screenshot-writer.m` | The Metal compositor (one renderer per output), the canvas background renderer (dot grid, shaders, tiled images, wallpapers), the tiled TIFF source, the cached-wallpaper fallback and the screenshot writer |
| `frame-driver.m`, `scene-writer.m`, `config-watcher.m`, `session-watch.m` | The per-display frame timer, asynchronous scene saves, config reload watching, wake/session/Space watching |
| `window-manager.m`, `window-events.m`, `window-observer.m` | Adoption, placement and closing of windows; event-driven tracking; batched read-only observations |
| `focus-driver.m`, `navigation-coordinator.m`, `cycle-hold.m`, `pointer-hover.m`, `canvas-cursor.m` | Native focus requests, window navigation, hold-to-commit cycling, the pointer policy, the canvas's own cursors |
| `resize-coordinator.m`, `resize-driver.m` | Size transactions (read the window, set its size, read it again) through Accessibility |
| `hotkeys.m`, `tap-keys.m`, `input-sources.m`, `hot-corners.m`, `pan-launch.m` | Global hot keys, tap bindings, keyboard input sources (`switch-layout`), hot corners, pan-momentum timing |
| `trackpad-gestures.m`, `multitouch-source.m`, `dock-guard.m`, `native-input.m` | The touch recogniser, the MultitouchSupport source, the Dock-control guard, the event taps and native-window pointer ownership |
| `ipc-server.m` | The IPC server (DriftWM's framing) |
| `onboarding.m`, `login-item.m`, `system-takeover.m` | The permission window, the login item, the Stage Manager and window-tiling takeover |
| `native-desktop-cli.m`, `loader-service.m`, `dock-reload.m` | `Infinify native-desktop`, the launch daemon client, the reload after a Dock restart |
| `native-presenter.m`, `native-display-space.m`, `native-views.m`, `native-transition.m`, `native-placement-validation.m`, `native-family.m`, `native-replica-family.m`, `native-replica-input.m`, `native-pointer-grab.m`, `native-relative-motion.m`, `native-tablet.m`, `native-decorations.m` | Compositor mode and the scoped native presentation: the client of the Dock helper, display and Space reads, one view per display, family reads and captures, replica input, window chrome ([COMPOSITOR-MODE.md](COMPOSITOR-MODE.md)) |
| `*-regression.m`, `../../tests/e2e/` | Headless regressions of the files above and the end-to-end scripts that build and run them ([Tests](#tests)) |

The Accessibility focus and size adapters the shell links are `native/focus/focus.m` and `native/resize/resize.m`.

## Desktop mode

DriftWM is a compositor: it is the session, not an app one launches. A normal run of Infinify is that for macOS, as far as public API goes: it replaces the desktop instead of sitting on it in a panel. The parity contract keeps what this section describes at `implemented_unverified`; [docs/parity/README.md](../../docs/parity/README.md#status) says what is still open.

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
  as soon as both are there. Stage Manager is no part of that check: the run
  switches it off itself ([Stage Manager and window tiling are off](#what-a-normal-run-is)
  below). macOS gives Screen Recording only to a process
  started after the grant, so the window says so and Relaunch starts the run
  again: the same executable with the same arguments, in the same process,
  after the usual cleanup, so a run started by the login item stays the login
  item's. A saved scene that could not be loaded is shown in the same window
  with Quit alone. Autostart commands run when the canvas opens, not while this
  window is up, so a relaunch does not start them twice.
- **Stage Manager and window tiling are off while the canvas is open.**
  macOS moves windows by itself in two ways that fight a canvas that places
  them: Stage Manager shrinks every window outside the current stage into a
  thumbnail in its strip, and window tiling snaps a window dragged or
  resized to an edge to half or the whole of the screen. When a normal run
  opens its canvas (not `--windowed`, `--manual` or `--only-pid`) it
  writes `false` to four keys of `com.apple.WindowManager`: `GloballyEnabled`
  (Stage Manager), `EnableTilingByEdgeDrag`, `EnableTopTilingByEdgeDrag` and
  `EnableTilingOptionAccelerator` (the three window-tiling drag switches of
  Desktop & Dock: the side edges, the top edge and the Option key).
  `EnableTiledWindowMargins` is left alone: it only sets the gap between tiled
  windows. The write is `CFPreferencesSetAppValue`, as `defaults write` does,
  and WindowManager follows it live: nothing is restarted, and in particular
  not the Dock, whose helper the compositor needs
  (`native/desktop/system-takeover.m`, a translation of Sunlight's takeover
  preferences, see its header for the functions and lines).
  - **Before the first write**, the originals of the four keys are read and
    written atomically (aside, fsync, rename) to
    `~/Library/Application Support/Infinify/window-prefs-snapshot.plist`; a key
    that was absent is recorded as absent and removed again at the end, never
    defaulted. Each write is read back. If one does not stick (a managed
    preference, for one) every key written is put back, the file is removed
    and the run goes on with the settings as they were, with one line on
    stderr that says so. Stage Manager then is a note like any other run's.
  - **At every orderly end** the originals go back, after the canvas is gone
    and every window has been returned (so none is still parked or scaled when
    Stage Manager comes back on): the quit action and `msg action quit`, the
    exit chord, SIGTERM, SIGINT and SIGHUP, a log out (AppKit's quit), a
    relaunch, and `exit()` from anywhere else. One line on stderr names the
    values put back. Run in the guest: `msg action quit`, SIGTERM, SIGHUP,
    SIGINT and an AppleScript quit; the exit chord, a real log out, a relaunch
    and an `exit()` reach the same code and were not run.
  - **A run that did not end** (`kill -9`, a crash, a power cut) leaves the
    file and the keys as the run set them. The next normal launch puts the
    file's originals back first, as soon as it holds the single-instance lease
    and before it asks for any access, and takes over again when its canvas
    opens. Should some key not come back, the old file stays and is what the
    new takeover keeps as the originals, so a second crash cannot make the off
    values look like the user's.
  - **What the user changes while the run is up is theirs.** The end writes an
    original back only to a key that still holds the `false` the run wrote. A
    key the user switched back on in System Settings or Control Centre, or
    removed, stays as they left it and is named on stderr. Stage Manager
    switched on under the open canvas is not switched off again: it is named
    once on stderr, with what its windows will look like, and the run goes on.
  - Nothing here is a setting of Infinify's: there is no config key to leave
    the user's settings alone; use `--windowed`, `--manual` or `--only-pid`
    for that. Tiling a window by hand (Window menu, keyboard shortcuts)
    is not one of these four switches and is untouched.
- **Status notes go to stderr.** A status note ("Bookmark 2 saved", "Zoom
  limit reached", a refused shortcut, a window that was not adopted, `Windows
  are not managed: …`) is written to stderr, one line each, and nothing is
  drawn for it. A note is not written again while it stays up:
  a flashed one for two seconds, counted again from each renewal, so one that
  is renewed before it expired is one line. Once it has expired the same text
  is a line again: two identical refusals a minute apart are two events. A
  failed read of the window list, which is tried again about every two
  seconds, is one line per distinct reason. What a config file has
  wrong is drawn in the error bar
  ([Blur, window animations and the error bar](#blur-window-animations-and-the-error-bar)).
- **Quitting returns the native desktop.** Control-Option-Escape (until a
  binding takes that chord), a key bound to `quit` (DriftWM's default is
  Control-Option-Command-Shift-Q), `Infinify msg action quit`, SIGTERM and a
  log out all end the same way: fullscreens ended, the scene saved, panels
  closed, capture stopped, hot keys released, exit status 0. `msg quit` is not
  a command: the action is `msg action quit`.
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
  of it canvas: the output is the whole content area. It opens
  at launch with whatever access there is and never shows the permission
  window, registers no global shortcut, and ends by `Infinify msg action quit`
  or a signal (Control-C in its terminal). See
  [Nested development window](#nested-development-window).
- `--manual`: the chooser first, and nothing is adopted. The chooser stays
  open above the canvas, the one place a window is added or rebound from;
  closed there, it is gone for the run. Its Rebind list is made
  again by Refresh and after every Add: a placeholder that arose during the
  run (a source that closed) is offered after a Refresh, and a slot that was
  just rebound is not offered again. `--manual --windowed` opens the canvas at
  launch and the chooser above it.
- `--only-pid PID[,PID…]` with `--windowed`: only the windows of the named
  processes are managed, with or without Screen Recording access. See
  [Managing only named processes](#managing-only-named-processes).
- `login-item on | off | status`: see below. Handled before AppKit starts, like
  `msg`: no window, no privacy grant.
- `--debug-pointer` and `--native-helper RUNTIME_DIR NONCE_FILE`, both with
  `--windowed --only-pid`: the scoped development and test mode, with
  `--state PATH` for its own scene file
  ([Managing only named processes](#managing-only-named-processes),
  [Native presentation through a cooperative helper](#native-presentation-through-a-cooperative-helper)).
- `--native-desktop-helper RUNTIME_DIR NONCE_FILE`: compositor mode, which the
  launcher passes ([COMPOSITOR-MODE.md](COMPOSITOR-MODE.md)).
- `--windowed`, `--manual` and `--only-pid` never write Stage
  Manager or window-tiling settings ([What a normal run
  is](#what-a-normal-run-is)); a normal run does, while its canvas is open.

### Installed, signed, started at login

These are for the owner to run. No agent or test installed the app, registered
the login item or built with a real signing identity, and none of the three
steps below was run for this document.

1. `./scripts/install-app.sh` builds the bundle (`--built` takes the one
   already in `target/app`), copies its exact signed bytes to
   `~/Applications/Infinify.app`, and verifies the app and helper hashes. Set
   `$INFINIFY_SIGN_IDENTITY` during the build to sign with a code-signing
   identity (`security find-identity -v -p codesigning`); otherwise the build
   is ad hoc, and macOS ties both privacy grants to that signature. With
   `--built`, the installer preserves the identity already used for the build.
   The bundle in place is moved aside
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
by hand first (`Infinify msg action quit`) to let the agent take over. A second
launch that shares either its socket or saved scene now exits cleanly before
helper admission, scene loading, panels or autostart; it does not save the scene.
After a quit the login item stays registered and starts again at the next login, or at once with
`launchctl kickstart gui/$(id -u)/com.marengox.infinify.agent`.

Exit status: 0 for the quit action, `msg action quit`, the exit chord, a
signal, a log out, and Quit in the permission window. An abnormal end is not 0,
so launchd starts the app again: a crash, a relaunch whose `exec` failed (1),
and a run path that could not be created or safely owned (73), which
therefore retries at launchd's restart interval until the path is usable.
A run started by launchd has launchd's environment and no terminal:
[CONFIG.md](../../crates/desktop/CONFIG.md#started-at-login) says what that
changes for the config path, `exec-terminal`, `PATH` and relative paths.

### Compositor mode at login, and Dock restarts

These are for the owner to run; the commands below are the whole surface. The Dock helper
(native presentation of the real windows, the `native-desktop` path, described in
[COMPOSITOR-MODE.md](COMPOSITOR-MODE.md)) can be loaded from an owner-run terminal command with an
interactive `sudo` per load, or, with a team-signed build, started at login by a launch daemon. The design, the launch
daemon and its checks are in
[native/privileged/README.md](../privileged/README.md#launch-daemon-login-start-and-dock-reload);
what the app does is:

1. `~/Applications/Infinify.app/Contents/MacOS/Infinify native-desktop enable` (a build signed
   with a team identity, installed with `scripts/install-app.sh`). It runs the launcher's
   read-only `--check`, registers the launch daemon with `SMAppService`, opens System Settings >
   General > Login Items & Extensions for the owner's one approval, waits for it (up to three
   minutes), checks the daemon answers this app, records compositor mode as the login default in
   `~/Library/Application Support/Infinify/native-desktop/login.plist`, and registers the login
   item if it was not on. The login item's program is `Infinify login-start`, which starts compositor
   mode (`launch.sh --login`: no terminal, the launch daemon loads, the app is exec'd) when that
   record exists and capture mode as before when it does not. `login-item on` and `off` still manage
   only the registration of that item.
2. While compositor mode runs with the daemon on, the app watches the Dock (`dock-reload.m`). A Dock
   that restarts takes the payload with it; the app notices the new Dock, waits 1.5 s, runs the
   bundled launcher's `--reload` (the same recovery-aware logic as a manual start: journal handoff from
   the retired Dock, same boot session, no prompt) and hands the new helper's runtime and nonce to the
   native presenter, which reconnects with its usual authenticated audit and puts the windows back.
   Until then it says `Native presentation lost; restoring and reconnecting`, as before. A Dock
   restart during or within a minute of a load is a strike; at three in a row the app stops loading for
   this payload digest, remembers that across launches in `auto-reload-paused.plist`, prints why and
   quits with status 0 (so the login item is not restarted; the restarted Dock had reset the windows' transforms, so they are drawn at the screen's top-left corner until a by-hand run restores them from the journal).
   Running `Infinify native-desktop` by hand, or `enable` again, lifts the pause. A new build (another
   payload digest) is not paused.
3. `native-desktop status` prints whether compositor mode is the login default, the login item, the
   launch daemon, whether automatic reload is paused, and the launch record (a pending marker is
   reported as such: the launcher never loads over one). The launcher's login-time output is
   `~/Library/Application Support/Infinify/native-desktop/login.log`.
4. `native-desktop disable` removes the record and any pause, unregisters the daemon and, if `enable`
   had registered the login item, unregisters it too (which ends the instance launchd started); it
   leaves a login item the owner had turned on before. It stops no instance started by hand and
   deletes no launch record, runtime or journal.

What the app's stderr does under the login item: the launcher redirects its own output to `login.log` before it execs the app, so the
app's one-line notes (`Native presentation lost`, `The Dock restarted`, `Dock payload reloaded`, `Native presentation reconnected`, the
pause) land in that file too. A Dock restart leaves the windows at the top-left corner for about five seconds before they are back
where the canvas put them. What was run was run in the guest, never on the owner's Mac.

Ad-hoc builds carry no daemon property list and cannot enable this; they keep `native-desktop` in a
terminal with `sudo`. The launcher refuses an unknown or pending
earlier load, a journal that is not schema 3, a different boot session's journal, a live earlier Dock, a payload
that differs from the bundle.

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
  run it has not been observed yet. Compositor mode is the other way
  round, the window server placing the real windows with nothing over them
  ([COMPOSITOR-MODE.md](COMPOSITOR-MODE.md); the helper needs System Integrity
  Protection relaxed by the owner, see [native/privileged](../privileged/README.md));
  this covering panel is what capture mode runs.
- **A click reaches a window only once its application is in front.** An
  event posted to an inactive application is dropped by everything but a
  control that takes a first click (measured on a WKWebView and an Electron
  window). An unbound root press therefore waits for its exact native focus
  request to succeed, within the focus driver's 1.5-second budget, with its
  drags and release queued behind it. Delivery also requires the same observed
  window and foreground application. Failed, superseded or expired requests
  discard the unsent pair. Child activation retains its half-second wait;
  explicit `--no-native-focus` retains logical click delivery.
  `INFINIFY_DEBUG=1` in the environment prints one stderr
  line for each such press and each native focus request, and one every two
  seconds that says how the canvas is keeping up
  ([the frame line](#managing-only-named-processes)).
- **Stage Manager and window tiling are switched off by the run, not asked
  of the user.** With Stage Manager on, macOS keeps only the current stage's
  windows at their size and scales every other window into a thumbnail in its
  strip. The window's bounds, its picture and the place a click has to go are
  then the thumbnail's, and every application switch swaps which windows that
  is. This was seen on the first runs on real windows (2026-10-10): tiles
  blurred and still, clicks that did nothing, a capture size that swung
  between about 150 by 170 and the window's own. A normal
  launch writes the setting itself, together with the three window-tiling
  switches, for as long as its canvas is open, and puts the user's settings
  back ([the bullet above](#what-a-normal-run-is) has the rules). `--windowed`, `--manual` and `--only-pid` launches are not
  held and do not write. Not established: anything on a physical Mac (the
  evidence is the disposable macOS 27.0.1 guest), on the owner's Mac or on
  macOS 26; a Mac that sets these keys through a configuration profile
  refuses the write, and then the run goes on with the settings as they were
  and says so (that path is covered by the substituted-store regression only,
  not by a managed Mac).
- **A window on another desktop (Space): addressed, never run.** A window
  left on a desktop that is not the one shown is in no Accessibility list, so
  a click on its tile did nothing (`native focus … outcome=missing_window`,
  fourteen times in the owner's run of 2026-10-10, after opening Safari had
  made macOS switch desktops). For exactly that answer, and only while the
  window server still lists the window as that process's and as not on
  screen, the focus adapter
  brings the window forward by its window number the way yabai does
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
- **The volume, brightness and media keys are macOS's and every tap keeps off
  them** (owner report of 2026-10-29, build c49eae1 on a MacBook with macOS
  27.2: "brightness, volume, media control buttons don't work"; the config
  skips the `XF86Audio*` and `XF86MonBrightness*` rows on purpose, so macOS is
  meant to keep them). The top-row keys of a Mac laptop are no key events: they
  arrive system-defined (`NX_SYSDEFINED`, event type 14, subtype 8, an aux
  control button, `data1 = key<<16 | state<<8`), unless "Use F1, F2, etc. keys
  as standard function keys" is on (`com.apple.keyboard.fnState`; it was
  absent from the owner's Mac when read, the default, so the owner's keys are
  the system-defined kind). Cause, reproduced in the guest: the annotated
  session tap (`DWNativeInput`) asked for every event type, and an *active*
  tap at the annotated location makes macOS ignore these keys although the
  callback returns the very event it was given. It is not the callback's work
  (a bare tap that returns the event without looking at it fails the same
  way) and not the Dock helper (capture mode failed the same way). The tap now asks for the
  pointer, scroll, tablet and gesture types it acts on and nothing else
  (`DWNativeInputAnnotatedMask`, `native/desktop/native-input.m`); other taps were
  not the cause: the global trackpad, early title, Dock-control, navigation
  (listen-only) and hot-key taps never ask for types 13 or 14. Left as it was:
  `F3` (keycode 99) is taken by the default `F3 = zoom-to-fit` binding while
  Infinify runs (in the guest it reached the annotated location without
  Infinify and not with it); keycode 160 (the Mission Control key, which the
  hot-key tap maps to F3) and F11 never reached it even without Infinify.
- **A status text made of several notes is one line more.** Where a status text is a
  summary (`Shortcut unavailable: X (+1 more)`) or two notes joined by
  ` · `, that text is written after its parts: a launch with
  two refused chords, or a `--windowed` launch with neither grant, writes one
  line more than it has notes. Read from the code, not run.
- **Stale wording in one stderr line.** A window of 200x150 or more that is
  left out is still reported as `… not adopted: …. Choose windows adds it by
  hand.`, which holds with `--manual` only.
- **Unverified system behaviour:** `SMAppService` with an ad hoc signature and
  after a reinstall, the `launchctl kickstart` hint, `exec` of a process that
  has already started AppKit (Relaunch), and the quit at log out.

## Controls

A normal run draws no controls: everything below is a key, a pointer gesture
or `Infinify msg`. A status note is a line on stderr
([Desktop mode](#desktop-mode)).

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
- Volume, brightness, media and keyboard-backlight keys: macOS's, never taken
  or delayed by any Infinify tap, in every mode ([Limits of desktop
  mode](#limits-of-desktop-mode)). They are not bindable: the `XF86Audio*` and
  `XF86MonBrightness*` rows of the default table stay inert.
- Close and suspend: Control-Option-Q (`close-window`) asks the focused window's
  application to close it, by pressing that window's own close button through
  Accessibility; on a focused placeholder it dismisses the placeholder.
  `suspend-window` (no default key) does the same and leaves a stand-in behind.
  `Infinify msg close`, `suspend` and `relaunch` are the scripted forms. See
  [Managed windows](#managed-windows).
- Keys, pointer gestures and settings come from one TOML file in DriftWM's own
  grammar; [Configuration](#configuration) has the file, the modifier mapping
  and the default tables. With no file, DriftWM's default bindings apply. The
  chords named in this list are those defaults under the default super chord
  (Control-Option). Nothing on screen lists the chords the running app
  resolved: `Infinify --help` and the default table under
  [Configuration](#configuration) have them, three of which start a program.
- Tap bindings: a `[keybindings]` entry that is a bare modifier chord, such as
  `"alt+shift" = "switch-layout next"`, runs when the chord is pressed and let
  go with nothing else pressed in between. DriftWM's defaults bind none, so
  there is none until the config file writes one, and a normal run only.
  [Tap bindings](#tap-bindings) has the rule, what it needs of macOS, and that
  no chord has yet been pressed against it.
- Pan a display's camera: drag or two-finger scroll on empty canvas,
  Control-Option-drag anywhere, or a three-finger swipe
  anywhere. A pan that is still moving when the fingers lift or the button is
  released keeps drifting until friction stops it (`navigation.drift`; 0 turns
  that off). Zoom, pointer-anchored, up to 1.0 and down to half the zoom that
  fits every window: mouse wheel on empty canvas, Control-Option-wheel or
  Control-Option-two-finger-scroll anywhere, a two-finger pinch anywhere,
  or a three-finger pinch anywhere. The view actions below are the animated
  keyboard equivalents; [Camera motion](#camera-motion) has the
  details of drift, edge pan and the pointer speeds, and
  [Trackpad gestures](#trackpad-gestures) the rest of the gesture table and
  what macOS must be told first.
- View actions: while panels are open, the global hot keys bound to
  `zoom-to-fit` (Control-Option-Tab or F3, again to return), `home-toggle` (Control-Option-A), `zoom-to-fit` (Control-Option-W; press
  again to return), `zoom-in` (Control-Option-=), `zoom-out`
  (Control-Option--), `zoom-reset` (Control-Option-0 or Control-Option-Z) and
  `pan-viewport <direction>` (Control-Option-Command with an arrow key, one
  `navigation.pan_step`). Hot keys act on the display under the pointer, or
  the first display when the pointer is over no panel. 

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
  Control-Option with an arrow key (`center-nearest <direction>`) focuses the
  nearest window in that direction and flies the camera to it at the current
  zoom; Control-Option-C (`center-window`) centres the focused window, or the
  one nearest the middle of the view, at 1:1; Control-Option-X (`focus-center`)
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
  Control-Option-Command-drag
  (`center-nearest` as a mouse binding) steps to the nearest window the way the
  drag pulls the canvas: drag left to go right. Both settings are off by
  default. None of this has been tried with a real pointer:
  [Pointer motion, sloppy focus and pick mode](#pointer-motion-sloppy-focus-and-pick-mode)
  has the rules and the exact boundary.
- Bookmarks: Control-Option-1 to 4 (`go-to-bookmark N`) fly the camera of the
  display under the pointer to bookmark 1 to 4 (zoom is left alone and any Fit
  return is forgotten); Control-Option-Shift-1 to 4 (`set-bookmark N`) save the
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
  Control-Option-Command-Shift-Q.
- Option-drag on a window: move the logical world window, using Rust snapping
  and hysteresis with the `[snap]` settings. Add Shift to move its connected
  cluster. The press raises and focuses the window first, as DriftWM's does,
  and so does Option-right-drag, the resize binding
  ([Upstream behaviour gaps closed](#upstream-behaviour-gaps-closed)). Held within `navigation.edge_pan.zone` (100 points) of the edge of
  the display the drag began on, the drag pans the canvas under the window,
  faster the nearer the edge. A three-finger tap followed by a three-finger
  swipe on a window moves it the same way, edge pan included. Control-Option-Shift with an arrow key
  (`nudge-window <direction>`) moves the focused logical window by
  `navigation.nudge_step` world points. Capture mode moves the canvas tile;
  native mode presents the real window at its world placement.
- In native mode, an unmodified drag on recognized standard AppKit title chrome
  uses the same world-move gesture, converting pointer motion by the view's zoom.
  The app's underlying native frame stays fixed during that gesture. Traffic-light
  controls, document proxies and content keep their native input. Title recognition
  needs fresh Accessibility geometry; custom or ambiguous title layouts remain
  with their application. A press left to the application on a transformed window
  that the application then turns into its own window drag (the native frame moves,
  its size does not) is taken over at that first packet and continues as the same
  world-move gesture from the press point
  ([Dragging, resizing and context menus of a transformed window](COMPOSITOR-MODE.md#dragging-resizing-and-context-menus-of-a-transformed-window-full-desktop-dock-helper)).
  Finder's measured search-scope header below its toolbar also uses this gesture
  when its exact Accessibility structure is recognized. Its scope controls,
  Save button and filter toggle remain native. Physical Finder drags at 75% and
  100% zoom were checked in the macOS 27.0.1 VM.
- Window sizing. Control-Option-Shift-W (`zoom-to-fit-snapped`; also
  Control-Option with a four-finger pinch in) frames the focused window's snap
  cluster and nothing else, and a second press returns, as Fit does for every
  window. It moves a camera only and runs in every normal run. DriftWM's
  actions that give a window a new size are a different matter: `fit-window`
  (Control-Option-M, Option-middle-click, Option with a two-finger pinch on a
  window), `fit-window-snapped` (the same with Shift), and `fill-window`,
  `grow-window <direction>` and `shrink-window <direction>` (no default
  binding), with `Infinify msg resize WIDTH HEIGHT`, run in every normal run: the size is asked of the real window and read back from it, and the
  canvas takes the size the window ended at.
  [Window sizing actions](#window-sizing-actions) has what each does, and what
  has been run: disposable fixture windows, not yet any
  application of the owner's.
- Fullscreen, DriftWM's and not macOS's: Control-Option-F, Control-Option with
  a middle click on a window, or Option with a three-finger pinch in or out on
  a window (`toggle-fullscreen`) gives the focused window its whole display,
  alone, on the canvas's own Space; a second press puts the window, the camera
  and the zoom back. It ends by resizing a real window, as the sizing actions
  do, and runs in every normal run.
  [Fullscreen](#fullscreen) has the rules, how it differs from macOS's own
  full screen, and what has been run: fixture windows, not yet any application
  of the owner's.
- Cursor edge pan, off by default: Control-Option-E (`toggle-cursor-pan`)
  turns it on or off for the run, and `navigation.edge_pan.cursor_pan = true`
  starts with it on. While it is on, a bare pointer resting within
  `cursor_zone` (20 points) of a display's edge pans that display's view,
  except under the menu bar and the Dock ([Desktop mode](#limits-of-desktop-mode)).
  The toggle writes no status note.
- Control-Option-Shift-Command with an arrow key (`send-to-output <direction>`)
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
- Pin to screen: Control-Option-T (`toggle-pin-to-screen`) fixes the focused
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
  carries no hint for this.
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
  line on stderr says so and the other three remain.
- A window resized natively, by its application or by hand on the desktop,
  keeps that size on the canvas: the next look at the window (an
  Accessibility report, or the reconciliation once a second) hands the
  controller its size, which becomes the window's size on the canvas with its
  top-left kept, and the scene is saved. Resizing a window by dragging its
  edge on the canvas uses the same readback transaction
  ([Resizing a window with the pointer](#resizing-a-window-with-the-pointer)).

A click on a source asks for native focus of that one window only, through the
controller's focus request and the focus driver, which acts on the window whose
freshly validated identity matches the binding the controller named.
With `--no-native-focus` the shell activates nothing on a click (what the
forwarded click makes the application do itself was not tried); without
Accessibility access no input is delivered at all. Identity validation checks PID, process birth, window number, current
owner PID, and the last observed native bounds immediately around delivery.
The private per-window routing fields and signatures are referenced from
Cantrip (`cantrip_cua/src/macos/skylight.rs` at commit
`4da10af479701c8007074c65f9eb6a2db03c8ffc`; no code copied), see the headers of
`native-replica-input.m` and `main.m`.
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
is the contract and lists every difference. The parity contract keeps the rows for this section at `implemented_unverified` ("Some rows still contain known partial behavior; that status is not a claim that only testing remains", [What is still open](../../docs/parity/README.md#status)).

**At launch.**

- With Screen Recording and Accessibility access: no chooser. The canvas opens
  at once on every display and the app starts managing.
- With either missing: the permission window of [Desktop mode](#desktop-mode),
  with an Allow… button for each, Relaunch and Quit; the canvas opens from it
  once both are there. The app still never asks macOS for a grant by itself.
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
- A saved scene that failed to load suppresses it.

**Which windows.** Real windows only, as DriftWM manages toplevels and their
dialogs and never a popup, a tooltip or a helper surface. The candidates are
what the chooser lists, restricted to what is on screen: normal-layer windows
of regular (Dock) applications other than Infinify, at least 40x40 points. Of
those, with Accessibility access, a window is adopted when its application
reports it as a standard window or a dialog (Accessibility subrole
`AXStandardWindow`, `AXDialog` or `AXSystemDialog`), whatever its size or
title. Native discovery retains a readable WindowServer title when Accessibility
cannot supply one. If neither supplies a string, adoption waits and retries at
the existing two-second cadence; an unavailable title must not be invented as
"Untitled" and matched to the wrong saved document. A successfully read empty
title remains valid. One reported as anything else (a floating panel, a sheet, which
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
**including placeholders**, unless
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

**A window that appears later** is offered once its frame has held still for
50 ms, from one look at the window list to a later one. The first look is made
when its application reports the window created, where
[the events are in place](#event-driven-tracking), and by the poll otherwise;
the later ones by the poll, which looks every 80 ms while a window is waiting.
Its size is the native window's. Its place
on the canvas is never where the native window sits on the desktop: the macOS
default is `window_placement = "auto"`, beside the focused window's cluster;
`center` places it under `focus_placement`, and `cursor` centers it on the
pointer. Placement steps down the diagonal while the frame would sit exactly on
another window. It goes on top, takes the canvas's logical
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
Accessibility access stderr says so and nothing is pressed. The window
lookup skips Finder's desktop scroll area only when its process and exact
Accessibility role identify it as a non-window; unknown errors and duplicate
window matches still refuse the close.
The window
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
  next offered.
- A window whose capture failed, or that the controller refused, is not offered
  again until it has left the screen and come back, or the canvas is reopened.
  Until then another window of that application with a different title can
  take its waiting slot.
- If a read of the shareable windows fails it is tried again about every two
  seconds while Screen Recording access stands (two to three once the first
  pass has ended and [the events are in place](#event-driven-tracking), because
  the pass that retries then runs once a second), and stderr says so, once per
  reason.
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
  `--windowed` or without `--state`, and `--manual` beside it. Without
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


`tests/e2e/scoped-windows.sh` is the test. It builds
`native/fixture/scope-fixture.m` (a regular application with one titled
window holding an `NSButton`, a plain view that takes no first click and a
`WKWebView`, which reports to a file what reached it), starts three, names two
to `--only-pid`, and presses and releases on their tiles. It takes the foreground from the application
that has it and holds it until the fixtures exit, when macOS returns it.

- A click is judged by what the fixture was as it handled each event (active,
  key, main), which the fixture records with the event. A fixture that is no
  longer active when read afterwards lost the foreground to another
  application: the test prints `DISTURBED` with the frontmost pid and does not
  fail the click for it.
- Each native fixture is asked to put its window directly under the canvas
  panel, before
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

`./tests/e2e/scoped-native.sh` is read-only by default. Its explicit
`--live-owned-fixture` mode starts disposable fixtures, checks startup refusals,
adoption, focus, pan, zoom, move, resize, alpha, parking, continuous movement,
quit, client SIGKILL, a stalled main thread, helper loss and the default overlay
path. An independent WindowServer connection checks transforms and alpha before
and after recovery; a second disposable process checks that the scope excludes
its windows. Children are removed on every exit.

Under `--only-pid`, the scoped native tests also set `INFINIFY_DEBUG_TEST_PANEL=1` and, with native presentation, `INFINIFY_DEBUG_NATIVE_PANEL=1` (and `INFINIFY_DEBUG_NATIVE_VIEWS=2` with `--debug-pointer` to split the one test panel into two views): the test's canvas panel then stays visible at the floating level, ignores mouse events outside native presentation and keeps ordinary canvas input for its replica destinations inside it. These switches are read in `main.m` only with `--only-pid`; none is set in a normal run.

The whole-desktop form of this presentation, compositor mode of the Dock helper, is described in [COMPOSITOR-MODE.md](COMPOSITOR-MODE.md): one independent view per display, the arrival veil, dragging, resizing and context menus of a transformed window, drags between windows, popups, session and sleep, quit and restore, and its known limits.

### Event-driven tracking

A managed run with Accessibility access is told about changes to native
windows, the way the yabai window manager is, and keeps asking as a slower
safety net. There is no flag, no control and no extra permission for it: it is on whenever the app manages windows (Screen
Recording access, no `--manual`), the per-application observers need
Accessibility access, and it uses
public Accessibility and `NSWorkspace` API plus the one private call the
window test already used (`_AXUIElementGetWindow`). The parity contract keeps the rows for event-driven tracking at `implemented_unverified` ("Some rows still contain known partial behavior; that status is not a claim that only testing remains", [What is still open](../../docs/parity/README.md#status)).

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
access) has no observers at all.

Application discovery observes `NSWorkspace.runningApplications` and each
application's PID, activation policy and termination through KVO. Initial and
changed values are read on a separate serial worker, including the first
catalog, without periodically enumerating unchanged applications. Pending reads
are bounded and revision-checked, with a fresh process
birth check before AX registration. Catalogs and workspace notifications can
contain fresh wrappers for the same application; worker-side equality matching
retains the canonical observer and its original process-birth affinity. An
unchanged catalog scan keeps existing observers live. Periodic process-birth
checks cover admitted AX applications; catalog changes during a read require a
new read before discovery is considered current. Trust withdrawal, stop
and application identity replacement retire their KVO records and reject stale
results. `tests/e2e/window-events.sh` exercises this
lifecycle in memory with substituted catalog, process and AX boundaries; it
does not establish ordinary-application observation or a measured CPU saving.

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
  when it happens.
- A native move or resize, a new title and a close reach the canvas with the
  event instead of at the next 80 ms poll, and a new window is looked for when
  its application reports it. Against an 80 ms poll that is a small gain; the
  larger one is that an idle canvas reads the window list once a second
  instead of twelve times.
- One rule is new, and it is the only change to which windows count as
  closed: a window its application reported destroyed is closed once it is
  also off screen, even if the window list keeps its number. The poll alone
  never did that. It is meant for an application that keeps a closed window's
  object, whose tile would otherwise stay for good.
- The safety net is slower than the poll it replaces: a change no event
  announces is found within a second, where it was found within 80 ms.

**Known limits**, from reading the code:

- The new close rule has not been seen on a real window. Which applications
  report a window they keep as destroyed is not known. If an application
  reports a native tab as destroyed when another tab is selected, that tab's
  tile leaves the canvas on every tab switch and is placed afresh when the tab
  is selected again, where it would otherwise stay with its last picture. Minimizing
  and hiding are not expected to do this. The rule is one line
  (`-destroyed:info:` in `main.m`, the `kCGWindowIsOnscreen` test); without it
  a destroyed report only makes the window list be read at once.
- One application that does not answer, or refuses one of the six
  notifications for good, keeps the whole poll at its old pace for every
  application: nothing is gained
  over the poll while it runs.
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

## Window rules, widgets and pinned windows

DriftWM's per-window policy for the windows on the canvas: `[[window_rules]]`
in the config file, widgets fixed to the canvas, and windows pinned to a
display's screen. The user contract is upstream's `docs/window-rules.md`; the
decisions are the controller's, and
[RULES.md](../../crates/desktop/RULES.md) is their contract with every
difference from upstream. The parity contract keeps the rows for window rules, widgets and pins at `implemented_unverified` ("Some rows still contain known partial behavior; that status is not a claim that only testing remains", [What is still open](../../docs/parity/README.md#status)).

**What a config can do.**

- ⌃⌥T (`mod+t`, `toggle-pin-to-screen`) is a registered global hot key in
  a normal run, taken from every application while a canvas is open.
  `"mod+t" = "none"` under `[keybindings]` gives it back.
- `[[window_rules]]` entries act on each window
  as it appears: `position`, `widget`, `pinned_to_screen`, `output`,
  `focus_on_open` and `opacity`, and its `decoration`, border, corner and
  shadow keys change how the window is drawn ([Rendering](#rendering)).
  `[decorations] opacity` and `opacity_focused` dim windows too.
- `Infinify msg pin`, `msg opacity`, `msg action toggle-pin-to-screen` and
  `msg action move-to-bookmark NAME` run.
  `msg move` and `msg resize` refuse a pinned window, `msg focus` refuses a
  widget, and `msg state` lists a pinned window under `pinned`, not under
  `windows`.
- The scene file has a `pins` field while a window is pinned
  ([Persistence](#persistence-and-lifecycle)).

The pass rules (no flag, no default binding):

- A rule's `pass_keys` and `pass_mouse` act. With
  `pass_keys` on the focused window, the chords it names stop being
  Infinify's while that window holds the keyboard
  ([below](#passing-keys-and-presses-to-an-application)). A rule's
  `layer_order` is read and kept and does nothing, which is what
  upstream does with it for a window ([below](#layer_order)).
- The move binding (⌥ left drag by default) pressed on a pinned window
  drags it across its display's screen, and the trackpad move gesture (a
  three-finger double-tap and drag by default) over one does the same. A
  resize binding is swallowed, and the note reads "A screen-pinned
  window is not resized: unpin it first (toggle-pin-to-screen)" (since
  [the gaps were closed](#upstream-behaviour-gaps-closed) the press raises
  and focuses the window first).
- A mouse binding on a wheel notch (`wheel-up`, `wheel-down`) fires: one
  notch of a mouse wheel runs its action once. No default binding uses them.

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
  When a native-owned mouse gesture ends, adopting its displayed displacement
  also preserves a partially offscreen pin. Initial arrival still clamps a
  new pin fully inside its display; reusing that clamp on release made an
  existing pin jump inward. Relocation still requires the same source identity,
  generation, observed native frame and expected canvas frame, and rejects a
  repeated receipt after the frame changes.
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
- A screen change (a display connected, disconnected or resized)
  rebuilds every panel. A pin whose
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
window, and no key was pressed**.

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
- A chord macOS will not give back when it is registered again is named on  stderr ("Shortcut unavailable: …").
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

What is on screen: the canvas is DriftWM's dot grid
on black (or whatever `[background]` names); a
captured window has a soft shadow and its corners are clipped to
`[decorations] corner_radius`, 10 by default; a placeholder is a dark rounded
panel with a close glyph and the application's name; and `[decorations]`, `[background]`,
`[output.outline]` and the decoration keys of `[[window_rules]]` are applied
([Settings](#settings)): the three tables on the next reload of the config
file, a rule to the windows that reach the canvas after it, since a window
keeps the rule it arrived with. All of this is what the code draws and what `msg screenshot` showed for
stand-ins; a captured window and the panel on a display
have not been seen.

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
  identifier. ⌃⌥-click dismisses a placeholder while no binding claims that press, and the
  placeholder shrinks and fades as any dismissed stand-in does
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
  Leaving the desktop session stops root and child captures in both backends.
  Overlay mode retains its bindings and current pictures; returning restarts
  managed sources through visibility demand. Unmanaged canvases resume their
  existing healthy sources directly, and failed sources use capture recovery.
- **Frame pacing.** The scene is gone through once per refresh of the
  display, by the [frame timer](#rendering) below, and at no other moment
  while that timer runs. Every stream hands its frames to the main queue,
  each on a turn of its own and at a moment of its own, so a picture, an
  animation's step or a decoded chunk only marks its outputs and asks for a frame; the timer's frame
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
  pointer at rest.
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
  upstream does, to the dot grid; the reason is written to stderr and shown in
the [error bar](#blur-window-animations-and-the-error-bar) until a reload builds a program without one.
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

### Blur, window animations and the error bar

DriftWM's visual effects, drawn in a normal run by the same compositor. There
is no flag, key or command: the effects follow the config file and what
windows do. What the controller reports for them is
[`crates/desktop/EFFECTS.md`](../../crates/desktop/EFFECTS.md); how the
compositor draws them is [COMPOSITOR-NOTES.md](COMPOSITOR-NOTES.md), sections
17 to 25, whose host protocol (section 18) `canvas-renderer.m` follows.
**None of this has been seen in the app's own panel**: it was drawn offscreen
by the app's renderer from this controller's snapshots, and the app was run
through the same events without anyone looking at it.

What is on screen:

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
  the window is not drawn at all.
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
  shown there and nowhere else on screen, as upstream shows it, and stderr has
  every message of the load, its
  warnings in the same sorted order, so the first line there is the one the
  bar names. A background that fell back is named on stderr as well.

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
  rule's `size` is invisible for as long as
  that takes and a second more at most; a click at its place is taken or
  refused as for any window being resized, whether or not it is drawn.
- A background that fell back is shown in the bar and written to stderr. A
  problem in the config file is the bar's alone on screen; one about bindings
  that could not be registered, a `--super` chord the controller rejects and
  a load it refuses outright are lines on stderr alone. The app
  has been launched with a config that has two unknown actions and reloaded: stderr had the two
  warnings at every load and nothing else for them, but nobody looked at the
  panel, so the bar itself is compiled and read only.
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
section 17, which lists every difference from upstream). There is no flag,
command or control: two config keys act, and a `.tif` tile path draws the
picture. In the app itself neither cache's
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
  setting to pair `cache_shader` with here. Nothing appears on the error bar for it, as upstream shows nothing. A budget below one
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
  stderr and the error bar. A file with one tiled level and
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
  the error bar runs the lines into one and cuts it at the display's width.

## Configuration

A normal run uses DriftWM's TOML grammar for key bindings, mouse bindings and
settings. The parser, portable defaults and binding tables are upstream's own
code (`driftwm-core`); Infinify's macOS settings default `window_placement` to
`auto` when that field is omitted. Explicit `center`, `cursor` and `auto` values
are handled by the upstream parser.
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
events and a periodic check: every five seconds at rest, deferred for up to
thirty seconds during continuous camera, input, video or background frames.
The bound runs from the oldest display's actual host query, so another display's
refresh or decoder completion cannot keep postponing it.
Space/display/session/config changes still refresh immediately. The app reads
these settings; it never changes the Mac wallpaper.

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
  not an error while the run has read no file: the macOS built-in defaults apply,
  including automatic free-space placement. The app never writes the file.
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
  status notes on stderr. Every message
  also goes to stderr, upstream's own verbatim, a load's warnings in sorted
  order.
- **Live reload.** The app watches the file and its directory and reloads
  within about 150 ms of a change, whether the file is written in place,
  replaced by a rename, created or deleted. The `reload-config` action does the
  same on demand. Every load re-registers the hot keys. Deleting or moving the file away
  keeps the configuration and reports the read failure until the file is back;
  upstream's watcher says nothing about a deleted file and reports it only on
  `reload-config`.

### Modifiers and `--super`

| DriftWM | macOS |
| --- | --- |
| `ctrl` | Control ⌃ |
| `alt` | Option ⌥ |
| `shift` | Shift ⇧ |
| `super`, and `mod` while `mod_key = "super"` (the default) | the super chord: Control-Option ⌃⌥ unless `--super` says otherwise |
| `mod3` | none; such a binding is skipped with a warning |

`--super CHORD` picks the super chord at launch: a `+`-joined subset of `ctrl`,
`alt` and `cmd`. The default is `ctrl+alt`, leaving Command editing shortcuts and
Command-Tab with native applications. Configured `super`/`mod` follows this
selected chord; `mod_key`, authored bindings, unbindings and pass rules are
unchanged. `--super cmd` selects the Command mapping and gives upstream-literal chords (`mod+a` is ⌘A,
`mod+ctrl+Right` is ⌃⌘→), which takes ⌘A, ⌘W, ⌘Z, ⌘0 to ⌘4 and others away from
every application while the canvas is open. A chord the controller rejects is
reported on stderr and the default stays.

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
layout's Latin keysym; with `false` the binding is left out and stderr
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
| ⌃⌥Tab / F3 | `mod+Tab` / `F3` (Mac defaults) | `zoom-to-fit` toggle |
| ⌃⌥A | `mod+a` | `home-toggle` |
| ⌃⌥W | `mod+w` | `zoom-to-fit` |
| ⌃⌥⇧W | `mod+shift+w` | `zoom-to-fit-snapped` |
| ⌃⌥= / ⌃⌥- | `mod+equal` / `mod+minus` | `zoom-in` / `zoom-out` (repeat) |
| ⌃⌥0, ⌃⌥Z | `mod+0`, `mod+z` | `zoom-reset` |
| ⌃⌥⌘ arrows | `mod+ctrl+<arrow>` | `pan-viewport <direction>` (repeat) |
| ⌃⌥⇧ arrows | `mod+shift+<arrow>` | `nudge-window <direction>` (repeat) |
| ⌃⌥⇧⌘ arrows | `mod+alt+<arrow>` | `send-to-output <direction>` |
| ⌃⌥ arrows | `mod+<arrow>` | `center-nearest <direction>` |
| ⌃⌥C | `mod+c` | `center-window` |
| ⌃⌥X | `mod+x` | `focus-center` |
| ⌥Tab / ⌥⇧Tab | `alt+Tab` / `alt+shift+Tab` | `cycle-windows forward` / `backward` (repeat) |
| ⌃⌥1 to ⌃⌥4 | `mod+1` to `mod+4` | `go-to-bookmark 1` to `4` |
| ⌃⌥⇧1 to ⌃⌥⇧4 | `mod+shift+1` to `mod+shift+4` | `set-bookmark 1` to `4` |
| ⌃⌥Return | `mod+return` | `exec-terminal`: `$TERMINAL`, else `open -a Terminal "$HOME"` |
| ⌃⌥D | `mod+d` | `exec-launcher`: `$LAUNCHER`, else `open -a Apps` |
| ⌃⌥Q | `mod+q` | `close-window`: close the focused window, or dismiss a focused placeholder |
| ⌃⌥E | `mod+e` | `toggle-cursor-pan` |
| ⌃⌥T | `mod+t` | `toggle-pin-to-screen`: pin the focused window to the screen, or return it to the canvas |
| ⌃⌥⇧⌘Q | `mod+ctrl+shift+q` | `quit` |
| ⌃⌥Esc | none (the shell's own) | exit, until a binding takes the chord |

Those are 41 of upstream's 57 default key bindings. The default lock chord,
system media controls and screenshot commands are left to macOS as described
below. ⌥Tab and ⌥⇧Tab are taken from every application while a canvas panel is
open; rebind or unbind
`cycle-windows` in the config file to give them back. ⌃⌥⇧W is taken the
same way. The rest are not registered, so their chords stay with the
applications:

- Fullscreen and fitting run in every normal launch: ⌃⌥F
  (`toggle-fullscreen`), ⌃⌥M (`fit-window`) and ⌃⌥⇧M
  (`fit-window-snapped`). Configured bindings for `fill-window`, `grow-window`
  and `shrink-window` run too. The historical scoped sizing receipt used the
  former Command default; it is not evidence of physical delivery for these
  new default chords.
- 8 on media keys (volume, mute, brightness, play, next, previous), which macOS
  handles itself, and 4 on keys a Mac keyboard lacks (`Print`, `shift+Print`,
  `XF86AudioPause`, `XF86AudioStop`).

The two Mac overview defaults bring the total to 47 registered bindings. Explicit config bindings, unbindings and `disable_defaults = ["keys"]` take precedence. F3 uses a session event filter while desktop mode is active; Command-Tab does too only when explicitly selected (for example with `--super cmd`); the known Mission Control keycode 160 aliases F3. Other hardware packet formats remain unverified. No system shortcut preferences are changed.

**Key repeat.** A held hot key whose action upstream marks repeatable
(`zoom-in`, `zoom-out`, `pan-viewport`, `nudge-window`, `cycle-windows` and
`spawn`, `grow-window` and `shrink-window` among those that run) fires again after `[input.keyboard] repeat_delay` (200 ms) and then
`repeat_rate` (25) times a second. It stops when the key is released, when
another hot key is pressed, when the chord's modifiers are let go, and on quit. A held `spawn` binding therefore starts its command again
on every repeat, as upstream's does, with one exception: a `spawn` whose program
is not found when the config is loaded does not repeat at all, and a command
that `sh` reports it could not find or run (exit status 127 or 126) ends the
repeat in progress and says `sh could not run: <command>` on stderr.

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
  and never in a windowed run.
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

The Mac adapter leaves upstream's default lock, volume, brightness, media and
screenshot commands to macOS regardless of whether `swaylock`, `wpctl`,
`brightnessctl`, `playerctl` or `grim` happens to be on `PATH`:

| Upstream default | On a Mac without that program |
| --- | --- |
| `mod+l` = `spawn swaylock -f -c 000000 -kl` | not registered; the chord stays with macOS and the foreground app |
| volume up, down and mute = `spawn wpctl …` | nothing registered: macOS handles the volume keys itself |
| brightness up and down = `spawn brightnessctl …` | nothing registered: macOS handles the brightness keys itself |
| play, next and previous = `spawn playerctl …` | nothing registered: macOS handles the media keys itself |
| `Print`, `shift+Print` = `spawn grim …` | no such key on a Mac keyboard; screenshots stay the system's ⇧⌘3, ⇧⌘4 and ⇧⌘5 |

The default lock chord is left unregistered so the foreground application and
macOS retain their own behavior. The `send-to-output` arrow chords remain
registered when a canvas panel is open. A config can explicitly bind or unbind
these chords.

A binding **you** write in `[keybindings]` is always registered exactly as
written, a missing program included (that one only loses its key repeat, and
stderr says so once after the load). Explicit commands can
therefore opt into a system command; default behavior never substitutes or
starts one.

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
- Corners are watched only while a canvas panel is open. macOS's own Hot Corners (System Settings › Desktop & Dock) are
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
`CGWarpMouseCursorPosition` to the centre of the target display's usable area.
An absent active display falls back to the first registered display before
fullscreen restoration and momentum cancellation. No displays or no neighbour
produces no warp. This
action does not request a mouse/cursor association change; that state belongs
to the requesting application. With one display both do nothing, as upstream.

**Keyboard layouts.** DriftWM's layouts are xkb groups from its config. Here
they are the keyboard input sources enabled in System Settings › Keyboard ›
Input Sources, in the order of the input menu. `switch-layout next` and `prev`
step through them and wrap, and `switch-layout <index>` selects by 0-based
position (an index past the end selects nothing and stderr says so).
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
backend does.

### The usable area

DriftWM places and measures against an output's usable area: the output less
its panels and bars. On a Mac those would be the menu bar and the Dock, which
macOS draws above the canvas panels.

**The shell sends no usable area.** By the owner's decision of 2026-10-10 the
canvas covers each display edge to edge and reserves nothing for the menu bar
or the Dock: windows may sit beneath them, and both stay visible on top
([Desktop mode](#what-a-normal-run-is) has the panel that does it). Every
output is registered by its screen bounds alone and is usable whole, in a
normal run and a windowed one alike. This is a deliberate
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
  bar.
- **Drawing.** The coverage rule of [Rendering](#rendering) tests a window's
  frame against the whole output.
- **The controller can hold one.** `register_output` takes an optional
  `usable_rect_local` and `set_usable_area` replaces it, and the controller
  measures the rectangle wherever upstream measures an output less its
  panels, with scenarios of its own. The shell sends neither, so that side is
  inert. A shell file that read `NSScreen.visibleFrame` and sent both was
  written with those commands and removed before it landed, on that decision;
  it never ran in the app.

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
| ⌃⌥ two-finger scroll / wheel | zoom (`mod+trackpad-scroll`, `mod+wheel-scroll`) | zoom |
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

Normal runs only. DriftWM is handed swipe, pinch and hold gestures by libinput and binds
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
| 3 or more | raw trackpad touches, recognised by `trackpad-gestures.m`: in desktop mode from MultitouchSupport wherever the pointer is, otherwise from the touches AppKit hands the canvas view under the pointer |
| 2, pinching | AppKit's magnify events, sent as a `pinch` of 2 fingers: its scale is the running product of each event's `1 + magnification`, with no rotation and no delta |
| 2, scrolling | not a gesture: the `trackpad-scroll` mouse binding above |

Every canvas view accepts indirect touches and hands each event's touches to one
recogniser, `DWTrackpadGestures`, a state machine with no AppKit in it, fed
`(identity, x, y, phase, time)` in millimetres and emitting the begin, update
and end events. Those AppKit touches arrive only while the pointer is over a
canvas view of the key window, and in desktop mode only through the session tap
(`DWGlobalTrackpadInput`); the MultitouchSupport source described below, under
"Touches from anywhere", does not depend on where the pointer is, and feeds the
same recogniser the same calls. Its rules and every constant are written out at the
top of `trackpad-gestures.m` beside the libinput behaviour each imitates. In
short:

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
  the pinch was recognised, `rotation` the change of their angle in degrees.  Every finger counts toward that, not only the two touches
  `scale` is read from: when the fingers' mean distance from their own centre has
  grown or shrunk by 4 mm and by more than half of what the centre travelled, the
  touch is a pinch even if the farthest and the nearest finger drift the same way.
  A thumb and three fingers that spread while the hand slides (the shape of
  macOS's Show Desktop and Launchpad gestures, which are bound here as the
  four-finger pinches) are a pinch, not a four-finger swipe, even when the two touches'
  directions agree. In a sweep of synthetic hands (thumb-to-fingers
  separation 10, 20, 30 and 40 mm, hand drift 0 to 24 mm in steps of 4, 156 x 96 mm
  pad) the largest drift a spread could carry and still be a pinch was 4, 12,
  16 and 24 mm of drift; swipes of 3 to 12 mm and a 20 mm
  swipe with fingers fanning by up to 6 mm stayed swipes (a throwaway program,
  not kept; the regression keeps four of its hands). The rule is
  translated from Sunlight's Show Desktop reading (the header of
  `trackpad-gestures.m` has the lines); nobody has tried it on a hand.
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

**Touches from anywhere.** Desktop mode only; the windowed mode
keeps the views' touches. Implemented and compiled, **never run on a physical
trackpad**: no frame from MultitouchSupport has been received by this code on
any machine.

AppKit gives a view touches only while the pointer is over it, so three fingers
over a native window, or with another application key, reach no one that way.
The private MultitouchSupport framework, the one Mac gesture tools read, reports
every contact of every trackpad to a callback wherever the pointer is.
`multitouch-source.m` loads it with `dlopen` and six `dlsym` lookups
(`MTDeviceCreateList`, `MTRegisterContactFrameCallback`,
`MTUnregisterContactFrameCallback`, `MTDeviceStart`, `MTDeviceStop`,
`MTDeviceGetSensorSurfaceDimensions`), so there is no link-time dependency, and
registers a callback on every device that can say how big its surface is. The
technique, the contact layout and the wake restart are
[Sunlight](https://github.com/spacefarm-digital/sunlight)'s (MIT, Copyright (c)
2026 spacefarm, commit `afeea74b18e70ca49bf462d6fe462cf65deb2b32`); the file's
header says which lines.

- A contact is a 96-byte record, of which four fields are read: the path index
  (offset 16, stable while the finger stays down), the state (20), x (32) and y
  (36), both 0 to 1 with y 0 at the bottom. Only the states make-touch (3) and
  touching (4) are fingers; hovering, breaking off and lingering contacts are
  not. Neither the layout nor the unit of the surface size (hundredths of a
  millimetre) has been checked against a record of a running device; the
  regression builds records with offsets written out a second time and shows
  only that the code reads what it was told to read.
- The callback decodes on the framework's thread, stamps the frame with
  `CACurrentMediaTime()` (the contact's own timestamp is not read: its clock was
  not checked), and queues it for the main thread, where frames arrive in the
  order they were made. The first device with a finger on it is followed until
  it has none, so two pads never make one fictitious gesture; a followed device
  that sends nothing for 30 s loses the claim.
- `DWMultitouchFeed` turns a frame into the recogniser's calls: millimetres are
  the position times the surface in millimetres, y flipped to run towards the
  user; the identity is the path index; a finger seen first is `Began`, after
  that `Moved`, and one that lifts while others stay is ended by name; one frame
  closes each callback, and the empty frame the last lift brings ends the
  gesture at once, uncancelled. Fingers before the third are counted and not
  passed on.
- The third finger of a fresh touch asks the same admission the session tap
  asks (a canvas under the pointer, no button down, no gesture on a view, no
  geometry transition under way); a refusal stands until every finger has
  lifted, and the system keeps that touch. Whichever of the two sources sees the
  third finger first answers for both, so the other does not end the gesture the
  first began. The presses that end gestures (see above) end this one too, and
  the rest of that touch is ignored until the fingers lift.
- **Resting and palm contacts are not told apart.** The NSTouch path leaves out
  what AppKit calls `resting`, and a contact record carries no such flag.
  `DWMultitouchSource.resting` is where a classifier would go; nothing in the
  tree sets it, since any threshold would be a guess with no trackpad to tune it
  on. So on this path a thumb resting on the pad counts as a finger, and three
  fingers with a thumb down are a four-finger gesture. The regression shows only
  that a contact the block names is left out of the frame, the recogniser and
  the Dock guard alike.
- The source takes over only once it **delivers**: from the first frame with a
  finger, and not before. Until then, and whenever the framework, a function or
  a device is missing (one line on stderr, the reason), the views' touches and
  the session tap's stay exactly as they were. Once it delivers, neither of them
  feeds the recogniser. The session tap keeps what it did besides: owning the
  touch's AppKit events once it admits the touch, and the pointer-press guards.
  `INFINIFY_NO_MULTITOUCH=1` keeps the source from starting at all.
- Devices are stopped and started again a second after wake, and the source
  stops delivering, with the gesture in progress ended cancelled, until the next
  frame. A start that finds no device is tried again every ten seconds; a
  second trackpad attached after the first was found is not noticed until the
  next wake or restart. A Magic Mouse reports through the same framework and is
  not told apart from a pad.

**macOS takes three- and four-finger touches for itself first.** Infinify
changes no system setting. The system reads the fingers the canvas reads as
Mission Control, App Exposé, a Spaces swipe or a Launchpad or Show Desktop
pinch, and drives the Dock with Dock-control events (event type 30). While the
touch source delivers, a session event tap of its own (`dock-guard.m`) drops
those events, and only those:

- while the fingers on the pad, counted on the framework's thread before the
  main thread has seen the frame, or the recogniser's gesture in progress, are a
  count that a `[gestures]` binding takes. The controller answers which with
  `gesture_fingers` ([GESTURES.md](../../crates/desktop/GESTURES.md#the-finger-counts-a-run-binds)):
  the three tables as the config left them, whatever modifier a binding asks for,
  and the desktop's defaults; none while `set-trackpad` is off. The shell asks
  again after every config load and after any `set-trackpad` it sees run;
- and for 0.3 s after the last bound finger lifts or the gesture ends, since the
  system's swipe ends a beat later (Sunlight's tail).

Never for a count with no binding, and a touch that grows from a bound count to
an unbound one is handed back to the system at once, with no tail. Never when
the source is not delivering. Never for a touch the shell declined (a button
down, no canvas under the pointer, the canvas closed or the session away). The
decision is a plain function of a small state, `DWDockGuardDrops`, and the tap
runs on a thread of its own, so a busy main thread cannot make the system
disable it (a 5 s watchdog turns a tap the system disabled quietly back on).
Because a modifier is not part of the decision, a config that binds only
`alt+4-finger-swipe-up` still holds back the system's four-finger gestures
without Option.

The drop timing is Sunlight's, translated (`dock-guard.m`'s header maps each
function to its lines of `TrackpadPan.swift`): from the moment a bound count
lands until the last finger lifts the drop time is 0.3 s ahead of every report,
however the count moves in between, and the tail runs from the lift. Fingers lift
one by one, so the count passes through two and one on its way to none; an
earlier version of this guard decided by the count at each packet and started the
tail only when the count just before none was a bound one, which a staggered
lift never is. A stream of Dock-control packets (one gesture of the system's) is
also decided once, by its first packet, and the rest of it follows, so the Dock is
never given the middle or the end of a gesture whose beginning was dropped, nor
loses the end of one it was given the beginning of; a stream that goes a second
without a packet, or a packet of a format this code cannot decode that comes more
than 0.3 s after the last, is a new one. The packets of a Show Desktop or
Launchpad pinch may not be the DockSwipes the decoder knows (axis 1 to 3 of HID
type 23); they are then dropped or passed all the same, on the same decision.

Two taps ask the guard. `DWDockTap` is the one that exists for it. The session
tap `DWGlobalTrackpadInput` asks it too, for every Dock-control packet whatever
its format, so that a packet the first tap did not see, or was not installed to
see, is still decided (the second tap that sees a packet gets the first's answer).
Only when the guard has no live touch source (`undecided`) does the session tap
use its own rule: a DockSwipe whose beginning it saw while it owned an admitted
touch is dropped to its end, and since nothing else can be told apart, so is any
other Dock-control packet while it owns an admitted touch of three or more
fingers and for 0.3 s after. Neither session tap converts a type-30 packet to an `NSEvent`: AppKit's
"unrecognized type is 30" lines came from doing so, and `native-input-regression.m`
counts the conversions.

The tap needs Accessibility, which a normal run already needs. Without it, one
line goes to stderr, nothing is dropped, and the system's gestures stay on;
it is tried again whenever the native input is configured. It holds back
Dock-control events and nothing else: the Look up tap, three-finger drag and
the page swipe are not Dock control.

**Diagnostics, `INFINIFY_DEBUG=1`.** Lines on stderr, all beginning `debug: `:

- `multitouch: delivering, from a frame of N finger(s) (M framework callbacks so
  far)` and `multitouch: stopped delivering after N frame(s)`: the source went live
  or not. `multitouch: touch begins with N finger(s); the framework has called back
  M times, ... records by state {3:.. 4:..}`, then `N frame(s) in 1.00 s (X/s), K
  finger(s) now, peak P` each second of a touch and `touch ends after T s, N
  frame(s), peak P finger(s)`. `callback #N with R record(s) and none on the
  surface` (every 2 s) when the framework calls back and no record is a finger,
  with the states it sent; `MTDeviceStart(device ...) returned R`; and `20 s after
  the start the framework has called back N time(s)`, which says to touch the pad if
  it is 0.
- `dock-tap: installed (...)`, `not installed: AXIsProcessTrusted=0|1 ...` (every
  30 s), `the system disabled the tap (timeout|user input); enabled again`,
  `the watchdog found the tap disabled; enabled again`, `stopped`; and
  `dock-guard: Dock control is held back for the finger counts [3,4]` and
  `a touch source delivers ... | no touch source delivers ...`.
- `dock-control #N via=dock-tap|global-tap|annotated-tap <began|changed|ended|other>
  verdict=DROP|pass|undecided reason=<why> fingers=F gesture=G bound=[...] live=L
  refused=R tail_ms=T reports=N (+K similar not written) real=.. hid=.. axis=..
  phase=.. [fields: f..=..]`: each stream's first and last packet and any change of
  verdict, otherwise at most one line a quarter second. Reasons are
  `source-not-delivering`, `count-not-bound`, `touch-refused`, `bound-fingers`,
  `bound-gesture`, `tail-after-lift`, `stream-began-dropped`,
  `stream-began-with-system`; the session tap's own rule says what it saw instead.
  `via=annotated-tap ... reached-annotated-tap` is a packet that got past both
  session taps. The first packet of a stream and every packet of an undecoded
  format also print their non-zero integer event fields (`f..~` is a double), which
  is how a Show Desktop or Launchpad packet of an unknown format gets decoded.
- `gestures: touch of N fingers admitted as the canvas's (path multitouch|global-tap)`
  or `refused: <reason>`; `gestures: gesture_begin kind=pinch fingers=4 path=multitouch
  guard{...}` and `gesture_end cancelled=0|1 path=... guard{...}`: the recogniser's
  gestures, with the source that fed them (`multitouch`, `global-tap` or
  `view-touches`) and the guard's state at that moment.

That is the whole mechanism, and none of it has run against a trackpad. If the
source is not delivering (the framework or a device is missing, the opt-out is
set, a windowed run), or for the gestures the tap does not touch, the earlier
advice stands. Turn these off yourself in System Settings (the names recent
macOS releases use; they were not checked against this release's panes):

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
two-finger pinch over a window does nothing. `resize-window` by gesture begins the same resize grab a bound
press begins ([Resizing a window with the pointer](#resizing-a-window-with-the-pointer));
it has been run in controller scenarios only, never with fingers.

- `set-trackpad off` (no default key; bind it, or `Infinify msg action
  set-trackpad off`) stops all of the above, the two-finger pinch included,
  until `on`, `toggle`, a config change of `[input.trackpad] enable`, or a
  restart. The pointer, clicks and two-finger scrolling stay on: they are
  macOS's.
- A malformed entry in a `[gestures]` table is reported in upstream's words,
  as every config problem is, and skipped; the rest of the file applies.

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
| `window_placement` | where a window that appears by itself is placed: macOS defaults to `auto` when omitted; set `center` or `cursor` explicitly |
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
by the rules below. 

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
- **macOS's inertial scrolling does not pan the canvas.** The events macOS
  adds after the fingers lift are dropped for a scroll that panned, because the
  drift is computed from the fingers' own movement, as upstream does it, so
  what follows a flick is DriftWM's curve instead of the system's. A scroll forwarded to an application
  is passed on whole, inertia included. When a window comes under the pointer
  during a scroll that began by panning and takes it over, the rest of that
  scroll is the window's too, its end and its inertia with it.
- **Pan and zoom speeds are the config's.** A scroll pan and a swipe pan are multiplied by
  `navigation.trackpad_speed` (1.5) and a drag pan by
  `navigation.mouse_speed` (1.0). A wheel zooms
  by `zoom.step ^ (lines / 2 × zoom.mouse_speed)` and glides to
  its target the way the zoom keys do, and notches that arrive mid-glide add
  up. A pinch that zooms (which the `[gestures]` tables decide, see
  [Trackpad gestures](#trackpad-gestures)) is scaled by `zoom.trackpad_speed`
  (1.0) from the zoom it began at, and one that ends within 0.05 of 1:1 snaps
  to 1:1.
- **Pointer zoom stops where zoom-out stops.** Wheel and pinch go no
  lower than half the zoom that fits every window, and
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
  below it that does. Read from the code, not run.
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
  begins while a button is held. Upstream
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
it, by logical id) are fields
of the same file.
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
user ID is hung up on. A request is one line of at most 1 MiB (a longer one is
hung up on without a reply), at most 1024 connections are served at once (one
past it is told `1024 IPC connections are already open` in a line of its own
and closed; the app raises its open-file limit at launch for that, and gives
the commands it starts the limit it had), a reply that is not taken within one
second in all is dropped with its connection, and one that completes no request
for 30 seconds is closed, unless it has subscribed (see
[Event stream](#event-stream)). These are DriftWM v0.21.0's caps. A stale socket file is removed
only after connecting to it fails with connection refused. Normal launches hold
exclusive process-lifetime locks for both the socket and saved scene, before
helper admission or loading state. Separate instances need both separate socket
and scene paths. Parent-directory aliases resolve to the same ownership; leaf
symlinks and hard-linked scene files are refused. The adjacent mode-0600
`.infinify-lock` files remain after exit so every contender locks the same inode;
that filename suffix is reserved, and the descriptors close on exit or exec
after cleanup. A live socket also causes a clean duplicate exit without opening panels or saving.
An unsafe path, failed probe or socket setup error instead refuses startup with
a diagnostic and nonzero status. Socket and scene directories must already exist,
be owned by the current user and not be group/world writable; the default
Application Support directory is created when needed. The socket is removed on
quit. The server runs in normal runs only. As
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
After a failed scene load every request answers the load error and while a
native resize is unresolved `a native resize is pending`. That
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

## Nested development window

`--windowed [WIDTHxHEIGHT]` (default 1200x800) is the macOS analogue of upstream's
nested winit backend. Instead of one whole-display floating panel per display it
opens the canvas immediately in one ordinary-level, non-activating panel with a
single output whose stable id is `windowed` and whose rectangle is the whole
panel. No global hot keys are
registered, so use the pointer and `Infinify msg`; the permission window is
never shown, and the chooser only with `--manual`, above the canvas. With
Screen Recording access it
manages windows like a normal run unless `--manual` is given; without, the
canvas still opens and says on stderr that it manages nothing
([Managed windows](#managed-windows)), unless `--only-pid` names the processes
whose windows it is to manage, which it then does with or without that access;
`--debug-pointer` beside it serves the `DebugPointer` request a test presses
with ([Managing only named processes](#managing-only-named-processes)). It saves to
the default scene file, takes the default socket and reads the default config
file unless `--state`, `--socket` and `--config` say otherwise, so give a
development window its own when you also use Infinify normally. Pointer
bindings and settings from the config apply; key bindings are read but not
registered, and tap bindings are read but not watched.
`autostart` commands run, as they do under upstream's nested
backend, and hot corners bound for `windowed` or `*` are the corners of this
window while it is the window under the pointer. A size must be at least 960x480 and at most 16384 in each direction, or the app exits 64; the
panel is then clamped to the main display's visible area and centred on it. It is
a borderless panel like the whole-display ones: it cannot be dragged, it has no
button, it closes only when the app quits (`Infinify msg action quit`, or
Control-C in its terminal), and a display change rebuilds it. Window
navigation and native focus run here as in any normal run; with no hot keys,
cycling is `msg action cycle-windows …`, one
committed step each.

## Window navigation and native focus

Every normal run (the default launch and `--state`, with or without
`--windowed`) navigates between windows as DriftWM does and tries to give the
real window native focus. The controller's rules are in
[NAVIGATION.md](../../crates/desktop/NAVIGATION.md#window-navigation-actions)
and [FOCUS.md](../../crates/desktop/FOCUS.md); this section says what the shell
does with them.

**Native focus (raising the real window) has not been exercised live. It is
compiled, reviewed and covered by the headless coordinator regression only.**
No hot key, click or Option release has been exercised live
either.

### Flags

- Native navigation is part of every normal launch.
- `--no-native-focus` keeps focus logical: the shell activates no application
  and raises no window, for navigation or for a click, and installs no input
  observer. What a forwarded click makes the application do itself was not
  tried. Everything else in this section still happens. It is rejected (exit 64) when given twice.
- `--no-hover-forwarding` keeps pointer motion from applications: with no
  button down, nothing is posted to the window under the pointer. Only that
  delivery is off. The motion is still reported to the controller, so
  `focus_follows_mouse` and pick mode work as without the flag, and clicks,
  drags and scrolls are forwarded as before. It is rejected (exit 64) when given twice. A launch with it started and
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
rebinds them like any other key. Hot keys
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
launched and scripted through its socket, which has no pointer. Everything the shell does with a pointer below is
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
after its last pan. A hover never stops a flight or a drift. The shell then does what the reply says:

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

### A null controller hit (crash fixed 2026-10-29)

The controller answers a `hit` query with `{"hit": null}` when no source lies under the point
([POINTER.md](../../crates/desktop/POINTER.md)). The shell's `-[DesktopView hit:output:]` read that reply as
`NSDictionary *hit=reply[@"hit"]`, and on the ordered path (the renderer's applied order still showed a
placement under the pointer) it subscripted it as `hit[@"window"]`. JSON null arrives as `NSNull`, which has no keyed
subscripting, so build `c49eae1` raised `NSInvalidArgumentException` inside the event tap and ended the owner's
first compositor-mode run (`-[NSNull objectForKeyedSubscript:]` in `-[DesktopView hit:output:]`, called from
`-[Desktop nativeInput:event:]`). The reply is now read through `DWControllerHit` (`native/desktop/controller-hit.h`),
which accepts only an object, and on the ordered path only the very window the renderer put on top; a null, a missing
or a non-object `hit` is no hit on either path. The controller reply itself is also read as an object
(`NSDictionary *result=asDict(reply[@"data"])` in `-[Desktop call:raw:]`), so a reply whose `data` is not an object is
a failed call instead of an object-typed `NSNull`. `sh tests/e2e/controller-hit.sh` runs the real controller through
the C ABI (`register_output`, `attach`, `hit`, `snapshot`), checks that its empty-canvas answer parses as `NSNull`, that
the old expression raises the owner's exception, and that `DWControllerHit` gives no hit on both paths and still passes a
real hit; with the helper changed to the old behaviour the test aborts with that exception. It is in-memory only: it does not
show why the renderer's order and the controller disagreed in the owner's run, and that disagreement has not been reproduced.
Read from the code, one way it can happen: the placements the renderer draws (`layered_placements`) include a window whose source
is merely not minimized (`source_presentable`), while the controller's `hit` skips any window whose visibility change is still
pending (`source_interactive`: `Visible` and not `visibility_pending`), so a window being restored is drawn, found under the
pointer by the ordered walk, and refused by the controller with a null hit.

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
adding, rebinding or losing a source and a display change all withdraw a request that is still in flight.
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
cycling included, and stderr says so once:
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

## Window sizing actions

DriftWM's sizing actions are controller policy here: which size, which place,
which camera and what a second press gives back are upstream's rules, set out
in the [sizing contract](../../crates/desktop/SIZES.md). One of them,
`zoom-to-fit-snapped`, moves a camera and nothing else, and runs in every
normal run. The others end by giving a real window a new size, and they
run in every normal run.

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

**What has been resized.** Disposable fixture windows of the test's own, in a windowed run scoped to them without Screen
Recording access: `tests/e2e/scoped-sizing.sh`.
No application of the owner's has been resized by it, and no key chord has
been pressed by a test.

### When resize runs

Everything in this section runs in every normal run: `zoom-to-fit-snapped`, `fit-window`, `fit-window-snapped`, `fill-window`, `grow-window`, `shrink-window`, `msg resize WIDTH HEIGHT`, and a [window rule](#window-rules-widgets-and-pinned-windows)'s `size`, asked of a new window that matches it. Keys bound to those actions are registered where a run registers keys. A size is settled by reading the window back. There is no other switch and no config key for it.

All of them act on canvas windows. With a widget or a screen-pinned window
focused the five sizing actions and `zoom-to-fit-snapped` do nothing, as
upstream's do; `msg resize WIDTH HEIGHT` on one answers
`this window has no canvas size to set: it is pinned, fullscreen, a widget, or not on screen yet`;
and neither is in the way of a fill, pushed by
`fit-window-snapped` or framed by `zoom-to-fit-snapped`.

### What each one does

| Control | Action | What it does |
| --- | --- | --- |
| ⌃⌥⇧W; ⌃⌥ with a four-finger pinch in | `zoom-to-fit-snapped` | Frames the focused window's snap cluster: the windows joined to it edge to edge at `[snap] gap`, placeholders included, with `[zoom] fit_padding` around them. A second press returns to the view left, as Fit does. With no window focused, nothing. |
| ⌃⌥M; ⌥ middle click on a window; ⌥ with a two-finger pinch on a window | `fit-window` | Asks the focused window for the size of the display's view less `[snap] outer_gap` on every side, keeps its centre where it is, flies that display's camera to it at 1:1 and focuses it. A second press gives back the size it had before it was fitted or filled, around the centre of the frame the fit asked for, wherever the window has been moved by then; no camera moves. |
| ⌃⌥⇧M; ⌥⇧ middle click; ⌥⇧ with a two-finger pinch | `fit-window-snapped` | The same, and the windows snapped to it are pushed outward by the distance each of its edges travels, then brought back by the second press. |
| none (upstream suggests `mod+g`) | `fill-window` | Grows the focused window in place into the free space of the display that shows it: up to `outer_gap` from the edge of the view and `[snap] gap` from every other canvas window, pulling back an edge that sticks out. No camera moves. A second press puts it back where it was, at the size it had before it was filled or fitted. |
| none | `grow-window <direction>`, `shrink-window <direction>` | Moves the named edge of the focused window outward, or inward, by `[navigation] resize_step` (20) points; the opposite edge stays where it is. A diagonal moves two edges. Held, the key repeats. |
| `Infinify msg resize WIDTH HEIGHT [--id N]` | IPC resize | Asks one window for that size and keeps its centre. The reply echoes the size asked for. The window is raised over the other canvas windows, as upstream's `resize` raises a client, and is not given the focus. |

A config file binds any of them to a key, a mouse button, a trackpad gesture
or a hot corner in DriftWM's grammar, and all of those arrive through the same
action dispatch as `Infinify msg action`. None of them, `zoom-to-fit-snapped`
included, writes anything when it runs; a refusal is a status note on stderr.

By the code:

- The action's reply starts a size transaction on the window: a read of the window's size, one Accessibility size change,
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
- A press, a scroll or a gesture on the canvas during a sizing action's
  transaction is handled as at any other time.
- A window the resize driver will not touch is left alone without a
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

### Limits of sizing

- **Run on fixture windows only.** `tests/e2e/scoped-sizing.sh` resizes
  AppKit fixture windows through every action here. No
  application of the owner's has been resized: how each one clamps, a window
  with a sheet or an attached child window (no family guard stands before the size change), an application that animates its
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
  granted, because it answers before the window does. An earlier run of
  `tests/e2e/scoped-sizing.sh` is older than this:
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
- A sizing action's transaction takes the size the window has at its first
  read as its starting point.
- A window resized in its own application has that size on the canvas within
  a second (case 14 of the test), and a sizing action on it starts from there.
  A step pressed in that second is measured from the size the canvas still
  had.
- Escape cancels nothing: there is no monitor, and a size request ends by
  itself.
- Quitting while a size is owed waits for the window's answer (`Quit pending:
  waiting for native resize result`), five seconds at most.
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

## Resizing a window with the pointer

In every normal run, DriftWM's pointer resize works on real windows:

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
asked three sizes of a fixture in one run). What is drawn therefore follows the pointer by
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

## Upstream behaviour gaps closed

Nine places where the app behaved otherwise than DriftWM although
DriftWM's behaviour can be had here are closed. This is what each does. **None of it has been seen on a display or done with a
pointer**: the controller's side is covered by its scenarios, the shell's side
is built and read, and the app has been launched and driven over its socket
only.

| What | Behaviour |
| --- | --- |
| A press bound to `move-window`, `move-snapped-windows`, `resize-window` or `resize-window-snapped` (⌥ left or right drag, with ⇧ for the cluster) | raises and focuses the window under the pointer first, a screen-pinned window included, and the real window is then focused natively as after a click. A widget still refuses the drag and gets the press as a click. A resize press does this also where the resize is turned away (a detached placeholder or an application that takes no size). A resize press begins a resize in every normal run ([Resizing a window with the pointer](#resizing-a-window-with-the-pointer)) |
| `Infinify msg resize WIDTH HEIGHT` | raises the window over the other canvas windows, without giving it the focus. Asking again for the size last asked changes nothing, the stacking included, as upstream's does |
| A problem in the config file | shown in the error bar only; bindings left out, a `--super` chord or a load the controller refuses are status notes on stderr. Every message also goes to stderr |
| Several warnings in one file | the bar names the first in sorted order, the same at every load, and stderr lists them in that order |
| Pick mode over a widget or a pinned window | unchanged, and now read against upstream's code: a widget and a pinned window keep their pointer below `[zoom] interact_min`; where a canvas window lies over a widget the press is that window's and the widget gets nothing |
| `fit-window`, `fit-window-snapped`, `fill-window` after a step, a `msg resize` or a fill that the window clamped | measure it by the size it was last asked for, as upstream does |
| Several windows with a rule's `size` appearing together | each is asked, one after another in the order they appeared, and each is placed off the frames the earlier ones are taking, so they cascade as windows that already have the size do. One that is sized by hand, by an action or by `msg resize` while it waits is not asked afterwards |
| A rule's `size` | the window is placed for the size its rule names and then asked, a widget and a rule-pinned window too |
| `Infinify msg camera` printing `1950 -0` | unchanged: upstream's own client prints a negative zero for a centre whose Y is 0, so nothing rewrites it |

A press bound to `resize-window` uses the normal readback path.

What still differs from DriftWM in these nine places:

- A press while a size is still owed is dropped and focuses nothing, and so
  does a move press the controller refuses. Upstream has no such refusal and
  has by then raised and focused the window. A resize press that is turned
  away is raised and focused by itself.
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
- A resize drag ends what a window was last asked for; upstream goes on
  measuring by the last size the drag asked.

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
every normal run.

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

**What has been made fullscreen:** fixture windows of the test's own, in a windowed run of 1100x700
(`tests/e2e/scoped-sizing.sh`, cases 12, 13, 17, 20 and 22). No application of the owner's, no whole display,
and nothing was seen: the test bed has no Screen Recording access.

### What turns it on

`toggle-fullscreen` runs in every normal run, a rule's `fullscreen = true` is applied to a new window, and ⌃⌥F is registered as a global hot key while a canvas panel is open (never in `--windowed`). There is no other switch and no config key for it.

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
- Its display's hot corners do not fire unless that display's
  `disable_when_fullscreen` is `false`.
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

In every normal run:

- ⌃⌥F is taken from every application while a canvas panel is open. Unbind it
  in the config file (`"mod+f" = "none"`) to give it back.
- ⌃⌥ middle click and ⌥ with a three-finger pinch on a window ask that
  real window to change size.
- A config whose window rule says `fullscreen = true` makes a matching
  new window fullscreen.
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
  asked. The picture is whatever the stream has.
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
  display's fullscreen itself, and Quit does not cancel that size change.
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

## Pick-mode motion and TIFF failures

Two behaviours of the shell; the long forms are in
[POINTER.md](../../crates/desktop/POINTER.md#motion-below-interact_min-compositor-mode-2026-10-30) and
[BACKGROUND-NOTES.md](BACKGROUND-NOTES.md#1710-a-file-that-cannot-be-decoded-is-an-error-2026-10-30).

**Motion below `[zoom] interact_min` reaches no application in compositor mode.** `-[Desktop nativeInput:event:]` answers YES for a
mouse-moved packet over a managed native window that is a pick target (`-pickMotionAt:window:`, which is `DWPickMotion` in
`controller-hit.h` over the last render's output list and the window's placement: no controller call per packet), after the canvas
has had the motion, and `DWNativeInput` then drops it. Regressions:
`controller-hit-regression.m` (`tests/e2e/controller-hit.sh`) and `native-input-regression.m` (`tests/e2e/native-input-policy.sh`).
Not shown: a physical device, an application's cursor shape over a target, the canvas's own hover and edge pan during the same motion.

**A TIFF that cannot be read is an error and the dot grid, never an abort.** The tile reader (`background-tiff.m`) handed a failed
tile's message to its caller from inside an `@autoreleasepool`, so any failed block read ended the process with `EXC_BAD_ACCESS`; it
also decoded a tile of any declared size and a level of any size whole. DriftWM v0.21.0's `whole_lod` and `MAX_WHOLE_LOD_DIM` are
ported (`IFBGTiffWholeLevel`), a tile of more than 256 MiB of decoded samples is refused, and an exception under a read is an error.
`tests/e2e/background-tiff.sh` (`background-tiff-regression.m`) runs 59 crafted files, the program-level fallback and 6000 fixed-seed
mutations (a one-off 150,000 as well): none crashed or hung. Corrupt compressed data is still not detected (BACKGROUND-NOTES.md 17.8 item 9). Run on the host in memory; not in
the guest or on the owner's Mac.

## Known limits

The parity contract keeps everything in this file at `implemented_unverified` or below. [docs/parity/README.md](../../docs/parity/README.md#status) says: "Some rows still contain known partial behavior; that status is not a claim that only testing remains. Stable 120 fps is also unproven."

Each section lists its own limits: [Limits of desktop mode](#limits-of-desktop-mode), [Limits of sizing](#limits-of-sizing), [Limits of fullscreen](#limits-of-fullscreen), [Where a Mac window cannot follow DriftWM's](#where-a-mac-window-cannot-follow-driftwms), the "Known limits" paragraphs of [Managed windows](#managed-windows), [Event-driven tracking](#event-driven-tracking) and [Window rules, widgets and pinned windows](#window-rules-widgets-and-pinned-windows), [Camera motion](#camera-motion) and [Trackpad gestures](#trackpad-gestures); compositor mode's are in [COMPOSITOR-MODE.md](COMPOSITOR-MODE.md#known-limits). What holds across them:

- Native replicas have separate parented popup/sheet streams and implicit mouse capture across viewport bounds; these source paths remain unverified with ordinary applications. Pointer lock/confinement, display-boundary clipping and arbitrary family stacking remain incomplete. Compositor mode passes native drags between transformed windows (apart from presses in a window's top band at a zoom below 1); drag-and-drop across captured views is not implemented ([NATIVE-DRAG-ROUTING.md](NATIVE-DRAG-ROUTING.md)).
- Ad-hoc signing is local development packaging, not a notarized distribution build. Private SkyLight input symbols can change with OS updates; unavailable symbols leave live viewing functional and input disabled.
- Media keys, touch-screen gestures (`[touch.*]`), and every setting whose feature is absent are read and unused. The IPC surface is a subset of DriftWM's; an IPC focus is logical focus and camera navigation plus a native focus request, and an IPC move is a logical world move that never moves the native window. `--windowed` registers no global shortcuts and has one output.
- Hot corners are watched by polling the pointer (every 80 ms, 60 times a second while a flight, a drift or an edge pan runs), so a pointer that crosses a corner without resting there can be missed.
- [Tap bindings](#tap-bindings): whether macOS sends modifier changes to an app without Accessibility is not known here; if it does not, a tap fires only while Infinify is the active application.
- No [usable area](#the-usable-area) is sent, by the owner's decision: nothing is reserved for the menu bar and the Dock.
- Where the MultitouchSupport source is not delivering, macOS's own three- and four-finger gestures must be turned off in System Settings by the user for the canvas to receive those finger counts cleanly ([Trackpad gestures](#trackpad-gestures)).
- With the default bindings a detached placeholder cannot be dismissed with the pointer alone: a click focuses it, and `close-window` (⌃⌥Q, or `msg`) then dismisses it.
- Upstream's lock binding is not registered by the current macOS adapter; explicit config commands are left as authored. No default system command is run.

### Window navigation limits

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
  four-finger swipe) are described, with the boundary of what has been tried,
  under [Pointer motion, sloppy focus and pick mode](#pointer-motion-sloppy-focus-and-pick-mode).
  The canvas provides its own pick, resize and mouse-grab cursors; the captured
  application's own cursor is unavailable over a replica. Differences from
  upstream remain:
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
  refusal text is a status note on stderr.

## Tests

Run the regression a change touches, not the whole set. The scripts build what they need (`xcrun clang`, some also `cargo build -p driftwm-desktop --release`) and need an Apple Silicon Mac. The controller scenarios are `crates/desktop/tests/*_flow.rs` (`cargo test -p driftwm-desktop`), driven through the exported C ABI.

**In memory.** No window, event tap, permission request or application launch; they prove the policy or decision they name with substituted native calls, not that a real application accepts it.

| Script | What it covers |
| --- | --- |
| `tests/e2e/background-tiff.sh` | Crafted TIFF files and a fixed-seed mutation run through the real tile source and background program: a picture, or an error and the dot grid, never a crash |
| `tests/e2e/capture-configuration.sh` | The capture request and rate state |
| `tests/e2e/compositor-lifetime.sh` | The production CPU lifetime fence of the compositor's resources |
| `tests/e2e/controller-hit.sh` | The real controller's `{"hit": null}` answer through the shell's hit-reply helper, and pick-mode motion (`DWPickMotion`) |
| `tests/e2e/desktop-navigation.sh`, `tests/e2e/desktop-resize.sh` | The navigation coordinator and the resize coordinator and driver, with the real Rust library |
| `tests/e2e/family-geometry.sh` | Production renderer queries on family geometry |
| `tests/e2e/ipc-limits.sh` | DriftWM v0.21.0's IPC limits and the screenshot write, on the production IPC server and PNG writer |
| `tests/e2e/mac-wallpaper-refresh.sh` | The wallpaper refresh timing policy |
| `tests/e2e/multitouch-source.sh` | Synthetic MultitouchSupport contact records through the adapter into the recogniser, and the Dock-control decision |
| `tests/e2e/native-daemon.sh` | The launch daemon's and the Dock reloader's decisions |
| `tests/e2e/native-display-space-cache.sh`, `tests/e2e/native-placement-validation.sh`, `tests/e2e/native-presenter-readiness.sh`, `tests/e2e/native-view-transfer.sh`, `tests/e2e/native-family-recovery.sh`, `tests/e2e/root-capture-mailbox.sh` | The presenter and its verifiers with substituted reads: display queries, placement validation, ACK readiness, view transfer, family recovery, the capture mailbox |
| `tests/e2e/native-focus.sh`, `tests/e2e/native-frame-restore.sh` | The shipped focus adapter's refusals through its C ABI, and the resize adapter's frame regression |
| `tests/e2e/native-input-policy.sh` | The adapter's packet policy, including the native-drag takeover |
| `tests/e2e/native-launcher.sh` | The bundled launcher's modes against a signed stand-in bundle (it skips itself where an Infinify process is running) |
| `tests/e2e/privileged-regression.sh` | The Dock helper payload and its C client |
| `tests/e2e/system-takeover.sh` | The Stage Manager and window-tiling takeover against an in-memory preferences store |
| `tests/e2e/window-discovery.sh`, `tests/e2e/window-events.sh` | Window metadata and scheduling, and the application/KVO lifecycle |

**Live.** They start disposable fixture applications of their own and end them on every exit; each prints `LIVE NOT RUN` without its flag.

| Script | What it covers | Needs |
| --- | --- | --- |
| `tests/e2e/scoped-windows.sh --live-owned-fixture` | The managed product on fixture windows (`--only-pid`): focus, clicks through `DebugPointer` | Accessibility; takes the foreground |
| `tests/e2e/scoped-sizing.sh --live-owned-fixture`, `tests/e2e/scoped-resize-drag.sh --live-owned-fixture` | Sizing actions, `msg resize`, a rule's size and `toggle-fullscreen`; the pointer resize | As above |
| `tests/e2e/scoped-native.sh --live-owned-fixture`, `tests/e2e/native-drag-drop.sh --live-owned-fixture` | Native presentation against the cooperative host of `native/privileged`; a drag between two owned processes | Owned fixtures, WindowServer reads |
| `tests/e2e/scoped-native-decorations.py`, `-family.py`, `-group.py`, `-panels.py` (`--live-owned-fixture`) | The green control, a root with a popup and a sheet, two cooperative helpers, an owned utility panel | As above |
| `tests/e2e/physical-resize-edge.sh --live-owned-fixture` | One guarded physical right-edge drag per mode, on owned windows | Real CGEvents |
| `tests/e2e/privileged-fixture.sh --live-owned-fixture` | The protocol v2 server on hosts holding only owned fixture windows | Owned fixtures |
| `tests/e2e/compositor-dnd.sh --live-guest` | Real-HID drag-and-drop between two fixtures drawn away from their native frames | A disposable guest running Infinify in compositor mode (`DND_GSSH`, `DND_GSCP`) |
