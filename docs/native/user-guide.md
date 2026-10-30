# Infinify user guide

Infinify is the macOS port of DriftWM: an infinite canvas of live native windows that replaces the native desktop (the code behind it is mapped in the [native overview](README.md)).
The parity contract, [docs/parity/README.md](../parity/README.md), keeps what this guide describes at `implemented_unverified` or below, and says what is still open. Nothing in this guide is `verified`.

## Desktop mode

DriftWM is a compositor: it is the session, not an app one launches. A normal run of Infinify is that for macOS, as far as public API goes: it replaces the desktop instead of sitting on it in a panel. The parity contract keeps what this section describes at `implemented_unverified`; [docs/parity/README.md](../parity/README.md#status) says what is still open.

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
  adopts the windows that exist ([Managed windows](app/Windows/README.md#managed-windows)). With
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
  (`native/app/System/DWSystemTakeover.m`, a translation of Sunlight's takeover
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
  ([Blur, window animations and the error bar](app/Canvas/README.md#blur-window-animations-and-the-error-bar)).
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
  ([Event-driven tracking](app/Windows/README.md#event-driven-tracking)). A rebuild keeps the window
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
  [Managing only named processes](app/Windows/README.md#managing-only-named-processes).
- `login-item on | off | status`: see below. Handled before AppKit starts, like
  `msg`: no window, no privacy grant.
- `--debug-pointer` and `--native-helper RUNTIME_DIR NONCE_FILE`, both with
  `--windowed --only-pid`: the scoped development and test mode, with
  `--state PATH` for its own scene file
  ([Managing only named processes](app/Windows/README.md#managing-only-named-processes),
  [Native presentation through a cooperative helper](app/CompositorMode/README.md#native-presentation-through-a-cooperative-helper)).
- `--native-desktop-helper RUNTIME_DIR NONCE_FILE`: compositor mode, which the
  launcher passes ([COMPOSITOR-MODE.md](app/CompositorMode/COMPOSITOR-MODE.md)).
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
[CONFIG.md](../crates/desktop/CONFIG.md#started-at-login) says what that
changes for the config path, `exec-terminal`, `PATH` and relative paths.

### Compositor mode at login, and Dock restarts

These are for the owner to run; the commands below are the whole surface. The Dock helper
(native presentation of the real windows, the `native-desktop` path, described in
[COMPOSITOR-MODE.md](app/CompositorMode/COMPOSITOR-MODE.md)) can be loaded from an owner-run terminal command with an
interactive `sudo` per load, or, with a team-signed build, started at login by a launch daemon. The design, the launch
daemon and its checks are in
[docs/native/dock-helper/Daemon/README.md](dock-helper/Daemon/README.md#launch-daemon-login-start-and-dock-reload);
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
2. While compositor mode runs with the daemon on, the app watches the Dock (`DWDockReloader.m`). A Dock
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
  ([COMPOSITOR-MODE.md](app/CompositorMode/COMPOSITOR-MODE.md); the helper needs System Integrity
  Protection relaxed by the owner, see [native/dock-helper](dock-helper/README.md));
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
  ([the frame line](app/Windows/README.md#managing-only-named-processes)).
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
  (`native/app/Navigation/DWNativeFocus.m`, `forward()`), waits for it to appear in the
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
  ([MOTION.md](../crates/desktop/MOTION.md)).
- **macOS's own "Quit & Reopen"**, which System Settings offers after Screen
  Recording is switched on, reopens the app through LaunchServices, outside
  the login item's job: it is then not restarted after a crash until the next
  login. The permission window's Relaunch stays inside the job.
- **A moment with no display** ends every DriftWM fullscreen: the controller is told that every output is
  gone ([FULLSCREEN.md](../crates/desktop/FULLSCREEN.md)).
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
  (`DWNativeInputAnnotatedMask`, `native/app/Input/DWNativeInput.m`); other taps were
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
  [Managed windows](app/Windows/README.md#managed-windows).
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
  keyboard equivalents; [Camera motion](app/Navigation/README.md#camera-motion) has the
  details of drift, edge pan and the pointer speeds, and
  [Trackpad gestures](app/Input/README.md#trackpad-gestures) the rest of the gesture table and
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
  [Trackpad gestures](app/Input/README.md#trackpad-gestures). A click on a window gives it canvas focus and starts its native
  focus, then the click is forwarded; a click on empty canvas unfocuses, and
  focusing a canvas window in its own application (Command-Tab, the Dock) is
  followed by the canvas. Focusing means logical focus, raising in the canvas,
  and, when Infinify has Accessibility access, activating and raising the real
  window.
  [Window navigation and native focus](app/Navigation/README.md#window-navigation-and-native-focus) has
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
  [Pointer motion, sloppy focus and pick mode](app/Navigation/README.md#pointer-motion-sloppy-focus-and-pick-mode)
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
  ([Dragging, resizing and context menus of a transformed window](app/CompositorMode/COMPOSITOR-MODE.md#dragging-resizing-and-context-menus-of-a-transformed-window-full-desktop-dock-helper)).
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
  [Window sizing actions](app/Navigation/README.md#window-sizing-actions) has what each does, and what
  has been run: disposable fixture windows, not yet any
  application of the owner's.
- Fullscreen, DriftWM's and not macOS's: Control-Option-F, Control-Option with
  a middle click on a window, or Option with a three-finger pinch in or out on
  a window (`toggle-fullscreen`) gives the focused window its whole display,
  alone, on the canvas's own Space; a second press puts the window, the camera
  and the zoom back. It ends by resizing a real window, as the sizing actions
  do, and runs in every normal run.
  [Fullscreen](app/Navigation/README.md#fullscreen) has the rules, how it differs from macOS's own
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
  [Window navigation and native focus](app/Navigation/README.md#window-navigation-and-native-focus));
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
  [Window rules, widgets and pinned windows](app/Windows/README.md#window-rules-widgets-and-pinned-windows).
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
  See [Screenshots](app/Canvas/README.md#screenshots).
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
  ([Resizing a window with the pointer](app/Navigation/README.md#resizing-a-window-with-the-pointer)).

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
`DWNativeReplicaInput.m` and `Router.m`.
There is no global synthetic event fallback. Release-on-cleanup applies only to
the button this shell pressed in a source; user keyboard state is never
synthesized or released. While the app manages windows, a window that closes
leaves the canvas or leaves a stand-in ([Managed windows](app/Windows/README.md#managed-windows));
in a manual run a lost or closed source becomes an inert placeholder, unless
`close-window` or `suspend-window` asked it to close in the ten seconds before.
Stream errors detach rather than leaving stale content eligible for input, in both.

## Configuration

A normal run uses DriftWM's TOML grammar for key bindings, mouse bindings and
settings. The parser, portable defaults and binding tables are upstream's own
code (`driftwm-core`); Infinify's macOS settings default `window_placement` to
`auto` when that field is omitted. Explicit `center`, `cursor` and `auto` values
are handled by the upstream parser.
[CONFIG.md](../crates/desktop/CONFIG.md) is the controller's contract and has
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
  [error bar](app/Canvas/README.md#blur-window-animations-and-the-error-bar) shows the message
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
([Passing keys and presses](app/Windows/README.md#passing-keys-and-presses-to-an-application)).

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
([contract](../crates/desktop/CONFIG.md#tap-bindings)).

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
  ([Native focus is followed](app/Navigation/README.md#native-focus-is-followed)). Not tried.
- **When.** Taps are watched exactly while the config's hot keys are
  registered: from the moment the canvas opens (at launch, or when the
  permission window hands over: nothing is watched while that window is up)
  until quit, again after every config load and every rebuild of the panels,
  and never in a windowed run.
  A chord already held when watching starts never fires. The tracker holds no
  timer and nothing ticks it: neither the frame timer nor the check for lost
  input ([Camera motion](app/Navigation/README.md#camera-motion)) calls it.
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
  corners from firing while a window is [fullscreen](app/Navigation/README.md#fullscreen) on that
  display; set it to `false` for corners that fire all the same. The entry is
  still recorded, so after the window leaves fullscreen the pointer has to
  leave the corner and come back. Fullscreen runs in every normal run
  ([Fullscreen](app/Navigation/README.md#fullscreen)).

A corner's action runs as the same action on a key would at that moment, with
the pointer where it is and the modifiers that are down: `focus-center` takes
the window under the pointer, and a `cycle-windows` step fired with a modifier
held stays open until the cycle's hold modifiers are let go (see
[Cycling and hold-to-commit](app/Navigation/README.md#cycling-and-hold-to-commit)). Any other action
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
  ([the controller's list](../crates/desktop/NAVIGATION.md#the-usable-area)).
  With a Dock that stays on screen, a new or a centred window is centred on
  the display and not on what the Dock leaves of it, Fit pads from the
  display's edge and not from the Dock's, and a window that reaches that edge
  continues beneath the Dock. A normal run's output is its display whole, so
  the menu bar lies over the top of the output as the Dock lies over an edge
  of it: a window placed or centred high comes to rest partly beneath the menu
  bar.
- **Drawing.** The coverage rule of [Rendering](app/Canvas/README.md#rendering) tests a window's
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
| ⌥ / ⌥⇧ right drag | `resize-window` / `resize-window-snapped`: raises and focuses the window and resizes it from the edge or corner nearest the press, with its snap cluster for ⇧ ([Resizing a window with the pointer](app/Navigation/README.md#resizing-a-window-with-the-pointer)) | nothing |
| left drag just outside a window's frame | resizes the window by that edge (`resize_on_border`) | the same: the band is around the window |
| ⌥ / ⌥⇧ middle | `fit-window` / `fit-window-snapped` ([Window sizing actions](app/Navigation/README.md#window-sizing-actions)) | nothing |
| ⌃⌥ middle | `toggle-fullscreen` ([Fullscreen](app/Navigation/README.md#fullscreen)) | nothing |
| ⌃⌥ left drag | pan (`mod+left`) | pan |
| ⌃⌥ two-finger scroll / wheel | zoom (`mod+trackpad-scroll`, `mod+wheel-scroll`) | zoom |
| ⌃⌥⌘ left drag | `center-nearest` by pointer swipe (`mod+ctrl+left`): one step to the nearest window the way the drag pulls the canvas, taken 16 points from the press | the same |
| anything else | the application's; a press focuses the window first | nothing |

A move or resize binding pressed on a widget starts no gesture, and the status
line says why for two seconds; the widget then gets the press as a plain
click, as upstream's does. On a screen-pinned window the move binding drags
the window in screen space, and a resize binding raises and focuses it, starts
no gesture, says why, and is not passed to the application
([Window rules](app/Windows/README.md#window-rules-widgets-and-pinned-windows)).
Over a live window the lookup also names that window: a binding its
`pass_mouse` rule claims is not run, and the press or scroll goes to the
application as an unbound one
([Passing keys and presses](app/Windows/README.md#passing-keys-and-presses-to-an-application)).
A resize binding picks its edges from the pointer's place in the window, a 3×3 grid whose centre resizes from the
bottom right, as upstream's resize grab does. A mouse binding that names an
action first focuses the window under the pointer, a placeholder included, then
runs the action. A press bound to move or resize a window raises and focuses
it before the drag begins, as upstream's does, a screen-pinned window
included, and the native focus follows as after a click. A resize press does
so also where a resize is turned away (a detached placeholder or an
application that takes no size). A move the controller
refuses focuses nothing, where upstream has no such refusal. A move by
[trackpad gesture](app/Input/README.md#trackpad-gestures) focuses and raises its window too, as
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
controller, see [Camera motion](app/Navigation/README.md#camera-motion).

Trackpad gestures (the touch recogniser, the finger counts and the three commands) are described in [Trackpad gestures](app/Input/README.md#trackpad-gestures).

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
| `[gestures.*]`, `[gestures] swipe_threshold`, `pinch_in_threshold`, `pinch_out_threshold` | what a trackpad gesture does, see [Trackpad gestures](app/Input/README.md#trackpad-gestures) |
| `[input.trackpad] enable` | whether gestures are dispatched at all, until `set-trackpad` says otherwise |
| `[zoom] step`, `fit_padding` | `zoom-in` / `zoom-out`, `zoom-to-fit`, `zoom-to-fit-snapped` and the zoom-out limit |
| `[navigation] resize_step` | the step of `grow-window` and `shrink-window` (20); see [Window sizing actions](app/Navigation/README.md#window-sizing-actions) |
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
| `[session] suspend_on_close`, `restore_windows`; the same two keys of a `[[window_rules]]` entry, matched by bundle identifier as `app_id` and by `title` | whether a window that closes by itself leaves a stand-in; whether a saved slot whose window is gone stays as one after a discovery pass, at launch or when the canvas reopens. See [Managed windows](app/Windows/README.md#managed-windows) |
| `[[window_rules]] app_id`, `title`, `position`, `widget`, `pinned_to_screen`, `output`, `focus_on_open`, `opacity` | per-window policy for a window that appears, see [Window rules](app/Windows/README.md#window-rules-widgets-and-pinned-windows) |
| `[[window_rules]] pass_keys`, `pass_mouse` | the key bindings a focused window takes from Infinify, and the mouse bindings the window under the pointer takes, see [Passing keys and presses](app/Windows/README.md#passing-keys-and-presses-to-an-application) |
| `[background] type`, `path`, `texture`, `mirror_tile`, `transparent_shader`, `animate_fps`, `cache_shader`, `cache_budget_mb` | the canvas behind the windows: DriftWM's dot grid, a GLSL shader (upstream's `extras/wallpapers` work as they are), a tiled image, a wallpaper fixed to the view, or nothing. A leading `~/` in a path is expanded. PNG and JPEG, and as a tile a tiled pyramidal TIFF of any size. `cache_shader` bakes a static shader into textures, and `cache_budget_mb` bounds each display's cache of those and of TIFF chunks; on a Retina display the default 128 is too small for a baked shader around the canvas origin, and 256 or more is the value to set. See [Rendering](app/Canvas/README.md#rendering) and [Background caches](app/Canvas/README.md#background-caches) |
| `[decorations] border_width`, `border_color`, `border_color_focused`, `corner_radius`, `shadow`, `opacity`, `opacity_focused`, `default_mode` | the border, corner clip and shadow of every window and stand-in, and the opacity of every window that has none of its own from a rule or `msg opacity`: `opacity_focused` for the one holding the canvas's logical focus, `opacity` for the others, both 1 by default (a stand-in is always opaque, as upstream's); `default_mode` is `client`, `minimal` or `none` (`server` only through a window rule, as upstream) |
| `[decorations] bg_color`, `fg_color`, `title_bar_height`, `font`, `font_size`, `font_weight`, `title_align` | the chrome the compositor draws itself: stand-ins, and the title bar of a window a rule made `server`. `title_bar_height` is also the diagonal step of the placement cascade |
| `[[window_rules]] decoration`, `border_width`, `border_color`, `border_color_focused`, `corner_radius`, `shadow`, `opacity` | the same per window, from the rule the window matched when it reached the canvas (bundle identifier as `app_id`, and `title`), kept until it is gone; never for a stand-in |
| `[decorations] blur`, `[[window_rules]] blur` | the frost behind every window, or behind the window the rule matched when it reached the canvas; never behind a stand-in. See [Blur, window animations and the error bar](app/Canvas/README.md#blur-window-animations-and-the-error-bar) |
| `[effects] blur_radius`, `blur_strength`, `animate_blur_fps` | the frost: its number of blur passes (2), their spread (1.1), and how often it is refreshed over an animated background (20 a second; 0 never; 144 at most) |
| `[effects] animation_speed`, `animation_scale` | the open and close animations and the stand-in fades: the share of the remaining way covered per 60 Hz frame (0.5; 1 is instant) and the scale they grow from and shrink to (0.95; 1 fades only). Upstream's move, resize, fit and fullscreen animations, which the same two keys drive, do not exist here |
| `[output.outline] color`, `thickness`, `opacity` | the outline of every other display's view of the canvas; thickness 0 draws none |
| `[zoom] fit_padding` | also the margin of `msg screenshot all` |
| `focus_follows_mouse` | off by default; on, the window under a moving pointer takes the focus without being raised, see [Pointer motion, sloppy focus and pick mode](app/Navigation/README.md#pointer-motion-sloppy-focus-and-pick-mode) |
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
([Window rules](app/Windows/README.md#window-rules-widgets-and-pinned-windows)).
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
([Managed windows](app/Windows/README.md#managed-windows)). With `--manual` nothing is matched and
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
([Event-driven tracking](app/Windows/README.md#event-driven-tracking)); ScreenCaptureKit buffers independently report pixel dimensions.

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
uncertain; while the size a [sizing action](app/Navigation/README.md#window-sizing-actions) asked for
is on its way, requests are answered as usual.

| Command | What it does now |
| --- | --- |
| `state` | Camera, zoom, the keyboard layout (the selected input source's name and short code), windows (id, bundle id as `app_id`, title, centre position, size, `is_widget`, `suspended` for a detached placeholder, and `mode`: `Normal`, or `Fit` or `Fill` while a [fit or fill](app/Navigation/README.md#window-sizing-actions) can still be undone; the readable form prints neither of those two, `--json` both), `pinned` (each screen-pinned window with its display and its `position` and `size` in `pinned_to_screen` rule coordinates; such a window is not under `windows` and has no `mode`), `fullscreen` (each [fullscreen](app/Navigation/README.md#fullscreen) window with its display; such a window is not under `windows` either; always empty in a default launch), outputs (stable id as `name`, `active`) and the active bookmark. The layer lists are always empty. |
| `subscribe` | Keep the connection and print the state now and again after every change, until the app exits. See [Event stream](#event-stream). |
| `layout [--short]` | The selected keyboard input source: its name, or with `--short` its first language code. Empty until the app has reported one, which it does at launch. |
| `camera [X Y]` | Read the view centre, or fly the camera there at the current zoom. A centre whose Y is 0 reads `-0` (`1950 -0`), as upstream's own client prints it: its Y-up conversion negates the zero, and nothing here rewrites that. |
| `zoom [LEVEL]` | Read the zoom, or animate to a level about the view centre. The level is clamped to the range the zoom shortcuts use and the reply is the level applied. |
| `focus [APP_ID] [--id N]` | Read the focused window. Setting makes a window the logical focus and, unless it is already wholly in view, flies the camera to it as upstream does: at 1:1 for a window with a bound source (at the current zoom with `[zoom] reset_on_activation = false`), at the current zoom for a detached placeholder. A pinned window is focused and raised with no flight; a widget, which only `--id` reaches, answers `window #N is a widget and cannot be focused`. For a window with a bound source the app also performs the controller's focus request on the native window when native focus is allowed (see [Window navigation and native focus](app/Navigation/README.md#window-navigation-and-native-focus)); that has not been run. |
| `move [X Y] [--id N]` | Read a window's centre, or move the logical window there (whole points). The native window is not touched. A move is refused while a gesture is active, when it would put the frame outside the 32-bit integer range every other request reads positions in, and for a pinned window (`this window has no canvas position to move: …`); a pinned window reads as the canvas point its pin shows. It is the one way to move a widget. |
| `resize [WIDTH HEIGHT] [--id N]` | Read the size, or set one; a pinned window and a widget answer upstream's `this window has no canvas size to set: …`. Setting one asks the native window for that size, keeps the window's centre where it is, raises the window over the other canvas windows without focusing it, as upstream's does, and answers with the size asked for, not the size the window ends up with; a detached placeholder is refused. While another window's size request is still unanswered it answers `a native resize of window N is still pending`. See [Window sizing actions](app/Navigation/README.md#window-sizing-actions). |
| `pin [on\|off] [--id N]` | Read whether a window is pinned to the screen, or pin or unpin it without moving it on screen. A live window only: a placeholder answers `stand-ins can't be pinned`. |
| `opacity [VALUE] [--id N]` | Read the opacity a window is drawn at, or set it (0 to 1; outside that is refused, not clamped) until the window is gone. A live window only. |
| `action SPEC...` | Run an upstream action string, below. |
| `bookmark [NAME] [X Y] [--delete]` | List bookmarks, get or set one, or delete it. |
| `close [APP_ID] [--id N]` | A window with a bound source: ask its application to close it (its close button, through Accessibility); it leaves no stand-in. A placeholder: dismiss it. |
| `suspend [APP_ID] [--id N]` | A window with a bound source: focus it, close it the same way and leave a stand-in. A placeholder: `window is already suspended`. |
| `relaunch [APP_ID] [--id N]` | A placeholder: open its application by bundle identifier; the next window of that application takes the slot. Answers `ok` once the request is made, also for an application that is not installed (status line and stderr then say so). |
| `debug-counters` | A small map of controller collection sizes; the keys are Infinify's own and not stable. |

`screenshot [--scale S] [-o PATH] [window [APP_ID] [--id N] | all | region X Y W H [--from-screen]]`
writes a canvas PNG; [Rendering](app/Canvas/README.md#rendering) has what it draws and where it
differs from upstream. Every request of upstream's protocol is answered: none
replies `<name> is not implemented on macOS yet` any more. `close`, `suspend`
and `relaunch` with no selector act on the focused window;
[Managed windows](app/Windows/README.md#managed-windows) has their rules and limits.

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
([Window sizing actions](app/Navigation/README.md#window-sizing-actions), [Fullscreen](app/Navigation/README.md#fullscreen)). Over the socket `cycle-windows` is always one
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
([Managed windows](app/Windows/README.md#managed-windows)), unless `--only-pid` names the processes
whose windows it is to manage, which it then does with or without that access;
`--debug-pointer` beside it serves the `DebugPointer` request a test presses
with ([Managing only named processes](app/Windows/README.md#managing-only-named-processes)). It saves to
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

## Upstream behaviour gaps closed

Nine places where the app behaved otherwise than DriftWM although
DriftWM's behaviour can be had here are closed. This is what each does. **None of it has been seen on a display or done with a
pointer**: the controller's side is covered by its scenarios, the shell's side
is built and read, and the app has been launched and driven over its socket
only.

| What | Behaviour |
| --- | --- |
| A press bound to `move-window`, `move-snapped-windows`, `resize-window` or `resize-window-snapped` (⌥ left or right drag, with ⇧ for the cluster) | raises and focuses the window under the pointer first, a screen-pinned window included, and the real window is then focused natively as after a click. A widget still refuses the drag and gets the press as a click. A resize press does this also where the resize is turned away (a detached placeholder or an application that takes no size). A resize press begins a resize in every normal run ([Resizing a window with the pointer](app/Navigation/README.md#resizing-a-window-with-the-pointer)) |
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

## Known limits

The parity contract keeps everything in this file at `implemented_unverified` or below. [docs/parity/README.md](../parity/README.md#status) says: "Some rows still contain known partial behavior; that status is not a claim that only testing remains. Stable 120 fps is also unproven."

Each section lists its own limits: [Limits of desktop mode](#limits-of-desktop-mode), [Limits of sizing](app/Navigation/README.md#limits-of-sizing), [Limits of fullscreen](app/Navigation/README.md#limits-of-fullscreen), [Where a Mac window cannot follow DriftWM's](app/Navigation/README.md#where-a-mac-window-cannot-follow-driftwms), the "Known limits" paragraphs of [Managed windows](app/Windows/README.md#managed-windows), [Event-driven tracking](app/Windows/README.md#event-driven-tracking) and [Window rules, widgets and pinned windows](app/Windows/README.md#window-rules-widgets-and-pinned-windows), [Camera motion](app/Navigation/README.md#camera-motion) and [Trackpad gestures](app/Input/README.md#trackpad-gestures); compositor mode's are in [COMPOSITOR-MODE.md](app/CompositorMode/COMPOSITOR-MODE.md#known-limits). What holds across them:

- Native replicas have separate parented popup/sheet streams and implicit mouse capture across viewport bounds; these source paths remain unverified with ordinary applications. Pointer lock/confinement, display-boundary clipping and arbitrary family stacking remain incomplete. Compositor mode passes native drags between transformed windows (apart from presses in a window's top band at a zoom below 1); drag-and-drop across captured views is not implemented ([NATIVE-DRAG-ROUTING.md](app/CompositorMode/NATIVE-DRAG-ROUTING.md)).
- Ad-hoc signing is local development packaging, not a notarized distribution build. Private SkyLight input symbols can change with OS updates; unavailable symbols leave live viewing functional and input disabled.
- Media keys, touch-screen gestures (`[touch.*]`), and every setting whose feature is absent are read and unused. The IPC surface is a subset of DriftWM's; an IPC focus is logical focus and camera navigation plus a native focus request, and an IPC move is a logical world move that never moves the native window. `--windowed` registers no global shortcuts and has one output.
- Hot corners are watched by polling the pointer (every 80 ms, 60 times a second while a flight, a drift or an edge pan runs), so a pointer that crosses a corner without resting there can be missed.
- [Tap bindings](#tap-bindings): whether macOS sends modifier changes to an app without Accessibility is not known here; if it does not, a tap fires only while Infinify is the active application.
- No [usable area](#the-usable-area) is sent, by the owner's decision: nothing is reserved for the menu bar and the Dock.
- Where the MultitouchSupport source is not delivering, macOS's own three- and four-finger gestures must be turned off in System Settings by the user for the canvas to receive those finger counts cleanly ([Trackpad gestures](app/Input/README.md#trackpad-gestures)).
- With the default bindings a detached placeholder cannot be dismissed with the pointer alone: a click focuses it, and `close-window` (⌃⌥Q, or `msg`) then dismisses it.
- Upstream's lock binding is not registered by the current macOS adapter; explicit config commands are left as authored. No default system command is run.
