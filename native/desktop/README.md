# Infinify native desktop shell

`./scripts/build-app.sh` builds and ad-hoc signs `target/app/Infinify.app` for
Apple Silicon / macOS 26+. The build does not launch anything. As in DriftWM,
where every toplevel is managed, the app puts every ordinary application window
on the canvas by itself once it has Screen Recording access; without that
access, or with `--manual`, it opens on the chooser and captures only the
windows picked there. [Managed windows](#managed-windows) has the rules.
Screen Recording permission is required for capture; Accessibility permission
is required for native input, for focusing a native window from the canvas and
for closing one. The chooser explains a missing grant and offers an
Allow… button: the app asks macOS for access only from that click, then opens
the matching System Settings pane. Screen Recording takes effect after a
relaunch. Automated probes and tests never request permissions or change privacy
settings or SIP. An ad-hoc signature changes with every build, so macOS drops
both grants on each rebuild; build with
`INFINIFY_SIGN_IDENTITY="<stable signing identity>" ./scripts/build-app.sh` to
keep them.

The app links the actual Rust desktop static library. Every connected display
gets a nonactivating panel and an independently persisted camera on the shared
world. One ScreenCaptureKit stream per source feeds every display that shows
it, and one compositor layer per display draws the canvas the way DriftWM does
([Rendering](#rendering)). This is continuous live capture of native
application content.
Ordinary native windows remain where their owners put them. Cameras and world
movement do not move, transform, park, or resize native windows.
[Window navigation](#window-navigation-and-native-focus) activates and raises
the one window it focuses, and nothing else.

## Controls

- Choose windows: add a selected native source, or explicitly rebind a saved
  placeholder using the chooser's drop-down. Same-source duplicate attachments
  are rejected; the existing world window is visible through every display camera.
  While the app manages windows by itself this is the manual tool: for a window
  it did not take, or to rebind one whose capture failed.
- Open canvas (chooser): show the saved world without adding a window, at its
  saved cameras only with `[session] restore_camera = true` (see
  [Persistence](#persistence-and-lifecycle)). Placeholders, panning, zooming and the view actions need no capture,
  so this works before any source is chosen and without Screen Recording access.
  Without that access a canvas opened this way manages no window and its status
  line says so.
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
  (Control-Option). The status line shows the pointer, window, view, pan and
  bookmark chords the running app resolved, and each toolbar tooltip its own
  action's;
  it does not list every bound key (the default table under
  [Configuration](#configuration) has the rest, three of which start a program).
- Pan a display's camera: drag or two-finger scroll on empty canvas,
  Control-Option-drag / Control-Option-scroll anywhere, or a three-finger swipe
  anywhere. A pan that is still moving when the fingers lift or the button is
  released keeps drifting until friction stops it (`navigation.drift`; 0 turns
  that off). Zoom, pointer-anchored, up to 1.0 and down to half the zoom that
  fits every window: mouse wheel on empty canvas, Control-Option-wheel
  anywhere, a two-finger pinch on empty canvas (Control-Option-pinch anywhere),
  or a three-finger pinch anywhere. The view actions below are the animated
  toolbar and keyboard equivalents; [Camera motion](#camera-motion) has the
  details of drift, edge pan and the pointer speeds, and
  [Trackpad gestures](#trackpad-gestures) the rest of the gesture table and
  what macOS must be told first.
- View actions: toolbar buttons Home, Fit, −, 1:1 and + on every canvas panel,
  and while panels are open the global hot keys bound to `home-toggle`
  (Control-Option-A), `zoom-to-fit` (Control-Option-W; press again to return),
  `zoom-in` (Control-Option-=), `zoom-out` (Control-Option--), `zoom-reset`
  (Control-Option-0 or Control-Option-Z) and `pan-viewport <direction>`
  (Control-Option-Command with an arrow key, one `navigation.pan_step`). Buttons
  act on their own display (in the two-viewport demo panel, the viewport last
  clicked, scrolled or pinched, else the first); hot keys act on the display
  under the pointer, or the first display when the pointer is over no panel.
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
- Window navigation, in every normal run (toolbar buttons Center, Previous and
  Next; the hot keys only while panels are open and not with `--windowed`):
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
  centre), so let those land first. The status line confirms ("Bookmark 2
  saved") or says the bookmark is missing ("No bookmark 2 yet", with the chord
  that sets it when one is bound). A bookmark holds a canvas position only,
  never a zoom. There is one registry of bookmarks for every display. It starts
  from the config's `[navigation.bookmarks]`, or from DriftWM's four corner
  bookmarks `1` to `4` at (±1750, ±1750) when the file has no such table;
  [Persistence](#persistence-and-lifecycle) says what a restart keeps. These are
  global hot keys only: with `--windowed`, use `Infinify msg bookmark` or
  `Infinify msg action` below.
- Every hot key, every mouse binding that names an action, and every view button
  on the toolbar runs an upstream action string through the same controller
  command as `Infinify msg action`. Camera motion is animated with the
  controller's upstream-derived lerp at `navigation.camera_speed`. The view
  and bookmark actions move cameras only; they never move, resize, focus or
  otherwise touch native windows. The window navigation actions also focus a
  window. If macOS refuses a hot key the status line names it and the
  toolbar still works. The Quit button and Control-Option-Escape call the
  shell's quit directly instead of sending the `quit` action, so exit never
  depends on the controller or on an active output. Control-Option-Escape stays
  the exit chord unless a config binding resolves to that chord, which then
  takes it. DriftWM's own `quit` binding, `mod+ctrl+shift+q`, is
  Control-Option-Command-Shift-Q. The experimental resize controls below keep
  their own gate.
- Option-drag on a window: move the logical world window, using Rust snapping
  and hysteresis with the `[snap]` settings. Add Shift to move its connected
  cluster. Held within `navigation.edge_pan.zone` (100 points) of the edge of
  the display the drag began on, the drag pans the canvas under the window,
  faster the nearer the edge. A three-finger tap followed by a three-finger
  swipe on a window moves it the same way, edge pan included. Control-Option-Shift with an arrow key
  (`nudge-window <direction>`) moves the focused logical window by
  `navigation.nudge_step` world points. None of this moves a native window.
- Window sizing. Control-Option-Shift-W (`zoom-to-fit-snapped`; also
  Control-Option with a four-finger pinch in) frames the focused window's snap
  cluster and nothing else, and a second press returns, as Fit does for every
  window. It moves a camera only and runs in every normal run. DriftWM's
  actions that give a window a new size are a different matter: `fit-window`
  (Control-Option-M, Option-middle-click, Option with a two-finger pinch on a
  window), `fit-window-snapped` (the same with Shift), and `fill-window`,
  `grow-window <direction>` and `shrink-window <direction>` (no default
  binding), with `Infinify msg resize WIDTH HEIGHT`, run only when the app is
  started with `--experimental-native-resize`. Without the flag they answer
  not implemented, as before, and their keys are not registered.
  [Window sizing actions](#window-sizing-actions) has what each does and the
  plain fact that none of them has resized a real window yet.
- Cursor edge pan, off by default: Control-Option-E (`toggle-cursor-pan`)
  turns it on or off for the run, and `navigation.edge_pan.cursor_pan = true`
  starts with it on. While it is on, a bare pointer resting within
  `cursor_zone` (20 points) of a display's edge pans that display's view. The
  toggle shows no status message.
- Control-Option-Command-Shift with an arrow key (`send-to-output <direction>`)
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
  no longer carries a hint for this.
  DriftWM's defaults do claim it under the default super chord (`mod+left` pans
  anywhere), so out of the box there is no pointer way to dismiss a placeholder.
  `[mouse.anywhere]` with `"mod+left" = "none"`, or a `--super` chord other than
  `ctrl+alt`, frees the press.
- Screenshots: `Infinify msg screenshot` writes a PNG of the canvas as the
  compositor draws it, off-screen content included: the active view, one
  window, every window, or a rectangle, at any scale. No key is bound to it.
  See [Screenshots](#screenshots).
- Return to desktop: stop capture, close panels, and show the chooser.
- Quit, the registered Control-Option-Escape hot key, or a key bound to `quit`:
  save and exit. The visible Quit button remains available if hot key
  registration fails.
- Resize status: explains that native layout resizing is currently unavailable.
  Resize the original application on the desktop; observation reconciles native
  bounds and capture dimensions without replacing persistent world geometry.

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

- With Screen Recording access: no chooser. The canvas opens at once on every
  display (in its one panel with `--windowed`) and the app starts managing.
- Without it: the chooser, as before, with its Allow screen recording… button
  and Open canvas. A canvas opened from there, and a `--windowed` canvas (which
  opens at launch either way), manages nothing and says why in the status line
  and on stderr: `Windows are not managed: Infinify has no Screen Recording
  access. …`. The app still never asks macOS for the grant by itself. Access is
  read when the canvas opens and macOS applies a new grant at the next launch:
  quit and reopen.
- `--manual`: the previous behaviour whatever the grants are. The chooser comes
  first, only windows picked there are captured, nothing is adopted and no saved
  placeholder is dropped. A source that closes leaves a placeholder to rebind,
  except one that `close-window` or `suspend-window` asked to close: when it
  goes within ten seconds of the command it leaves nothing, or a stand-in, as
  in a managed run. It combines with `--windowed`.
- Never in `--source`, `--demo`, `--demo-probe`, `--demo-probe-guard` or the
  owned-resize modes, which also reject `--manual` (exit 64). A saved scene that
  failed to load suppresses it too.

**Which windows.** What the chooser lists, restricted to what is on screen:
normal-layer windows of regular (Dock) applications other than Infinify, at
least 40x40 points. **Every such window is captured** while it is in view on
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
frontmost application has focused, the next read, at most about half a second
later, takes it as an activation. It then replaces the saved focus, is raised
and heads the most-recently-focused order, and if it is clipped on the display
that shows its centre that display's camera flies to it, at 1:1 unless `[zoom]
reset_on_activation = false`, a camera that `[session] restore_camera` restored
included. Without Accessibility access nothing follows, and the saved focus and
the cameras stay as the pass left them.

The same pass runs again whenever the canvas is reopened after Return to
desktop: the windows return to their slots, and the slot of a window that
closed in between is dropped, or kept as a stand-in with `restore_windows`.

**A window that appears later** is offered once its frame has held still from
one poll to the next (about 80 ms). Its size is the native window's. Its place
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
window number is gone from the system's window list or its process is gone; a
capture stream that fails while the window is still there keeps the old
behaviour, a detached placeholder to rebind from the chooser.

**Titles** follow the native window and are saved, because slots are matched by
title at the next launch.

**Capture on demand.** A ScreenCaptureKit stream runs only while its window is
in view on some display. It stops about two seconds after the window left every
view and starts again when it returns; a window that returns within those two
seconds shows its last frame at once, and one that returns later shows its
last picture, which the compositor keeps ([Rendering](#rendering)), until the
restarted stream delivers. With `--experimental-native-resize`
every stream runs continuously, as before.

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
  its window number, so that window stays on the canvas.
- ⌃⌥Q acts on the canvas's logical focus: the window last clicked in the
  canvas, the newest window, the one `msg focus` named or a navigation chose,
  or, with Accessibility access, the canvas window last focused in its own
  application (Command-Tab, the Dock), which the canvas follows twice a second.
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
  it; it is relaunched through `msg relaunch`; there is no toolbar button for
  close.
- A close or suspend request is forgotten after 10 seconds and a relaunch after
  30, as upstream forgets them, measured on the clock the app ticks every
  80 ms while the canvas is open. Within its 30 seconds a pending relaunch
  takes the next window of that application whatever its title; upstream
  narrows that to 5 seconds with an activation token macOS does not have.
  Opening an application that is already running with other windows makes no
  window, so such a relaunch simply lapses. `msg relaunch` answers `ok` for an
  application that is not installed, where upstream answers `<name> is no
  longer installed`.
- After Return to desktop and Open canvas the windows return to their slots,
  but one opened in between is treated as new: each is focused and flown to in
  turn, the last one winning. The limits of the first pass apply to every
  reopening: a window that is off screen without a matching title, still being
  moved after the two-second wait, or missing from both reads of the shareable
  windows loses its slot and is placed afresh when it is next offered.
- A window whose capture failed, or that the controller refused, is not offered
  again until it has left the screen and come back, or the canvas is reopened.
  Until then another window of that application with a different title can
  take its waiting slot.
- If a read of the shareable windows fails it is tried again about every two
  seconds while Screen Recording access stands, and the status line says so
  each time (stderr once per reason).
  Until one succeeds the first pass does not complete: nothing is dropped and
  later windows are neither focused nor flown to as new windows are (followed
  native focus aside).
- With a config file that was refused at launch, no slot is dropped or made a
  stand-in until a discovery pass runs with an accepted config: fix the file
  and reopen the canvas, or relaunch.
- Every poll makes one window-list query and one controller call per managed
  window; with very many windows this has not been measured.
- A press that Accessibility does not answer in time is treated as sent, so an
  application that does not respond gives no status note.

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
  window is not resized: unpin it first (toggle-pin-to-screen)".
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
| `size` | in a default launch kept with the window and not applied: the window keeps its own size, and a `position` centres that size. In an app started with `--experimental-native-resize` a new canvas window is asked for that size once it is placed, around the same centre ([Window sizing actions](#window-sizing-actions)); a widget, a pinned window and a window that takes over a saved slot are never asked. No rule has resized a real window |
| `fullscreen` | kept with the window and not applied: there is no fullscreen |
| `blur = true` | what lies beneath the window is frosted, whatever `[decorations] blur` says, see [Blur, window animations and the error bar](#blur-window-animations-and-the-error-bar) |
| `pass_keys = true` or a list of key combos | while the window holds the keyboard, those key bindings are not Infinify's: the chord reaches the application, [below](#passing-keys-and-presses-to-an-application) |
| `pass_mouse = true` or a list of mouse combos | a press or scroll over the window that one of those bindings would take goes to the application as an unbound one, below |
| `layer_order = N` | kept with the window and ignored, as upstream ignores it for a regular window, [below](#layer_order) |
| `preserve_aspect_ratio` | kept with the window; nothing is constrained for it |

A file with a key the grammar does not know inside a rule is refused whole with
upstream's TOML error (`unknown field …`), and the previous configuration stays
in force. A rule with neither `app_id` nor `title`, an unknown `decoration`
mode or a non-positive `size` is a warning on stderr and in the status line,
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
  cluster). The window follows the pointer point for point whatever the
  zoom, as upstream's pinned move does. Nothing snaps, the canvas does not
  pan when the pointer reaches an edge, and the frame is not held on the
  display: it can be dragged partly off it, never wholly, because the point
  it was taken by stays on a display, as upstream's confined cursor keeps it.
  A pointer over the toolbar strip, or outside the panel of a `--windowed`
  run, counts as at the nearest point of the display's edge. Upstream holds
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
- It is not resized: a resize binding pressed on it gives the note "A
  screen-pinned window is not resized: unpin it first
  (toggle-pin-to-screen)" and the press is swallowed. `nudge-window` and
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
  The resize swipe is gated for every window; over a widget it pans. A window
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
  space; here a resize press is swallowed with a note, the resize swipe is
  the gated one of every window, and there is no compositor title bar to
  drag. The pointer drag does not focus or raise the window, where upstream's
  press does both first (a press bound to move focuses no canvas window here
  either); the gesture does both.
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
- With `--experimental-native-resize` no handle is drawn or hit on a widget or
  a pinned window, and a handle of the focused window that lies under a pinned
  window is neither drawn nor hit. The [sizing actions](#window-sizing-actions)
  that flag turns on leave both alone as well: with a widget or a pinned
  window focused they do nothing, `msg resize WIDTH HEIGHT` answers
  `this window has no canvas size to set: …`, and a rule's `size` is not asked
  of either.

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
  the status line ("Shortcut unavailable: …").
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
  chord (`mod+q` and `ctrl+alt+q` are both ⌃⌥Q under the default `--super`);
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
  output; the 64-point toolbar strip is not part of an output. A pinned
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
  redraws only the outputs that show that window, a burst of frames in one
  turn of the run loop once, and nothing is drawn while nothing changes.
  Streams are configured with `colorSpaceName = sRGB`, which the compositor's
  colour handling requires, and a queue depth of 5 instead of 3, because the
  compositor holds the current buffer and briefly the one before it. When
  capture on demand stops a stream, the last picture stays, so a window whose
  placement returns is not blank until its stream delivers again. A window
  that has never delivered a frame is the chrome background colour inside its
  border and shadow.
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
  status line too, behind a problem in the config file itself, until a reload
  builds a program without one.
- **Autorelease pools.** Metal hands out autoreleased drawables and encoder
  contexts. Each layer update is drawn inside a pool of its own, and the main
  loop of a normal run has one per turn, so a redraw issued from a poll, the
  launch's first frame or the quit-pending loop frees what it made.
- **Animated backgrounds and the frame timer.** There is one frame timer, at
  60 Hz, and three things keep it running: [camera motion](#camera-motion) (a
  flight, a drift, an edge pan), a shader background that reads `u_time`,
  redrawn at 60 Hz capped by `animate_fps` and only while a panel that shows
  it is open, and a window that opens or leaves (an open or close animation, a
  stand-in's fade, [below](#blur-window-animations-and-the-error-bar)), drawn
  on every tick. It stops when none of the three is left, so the frames of an
  opening window end with its animation. While a background or an animation
  alone keeps it running it ticks no camera and watches no hot corner: the
  idle poll goes on doing both every 80 ms, exactly as when the timer is
  stopped, and regains 60 Hz for the camera when it finds motion. The
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
  In an app started with `--experimental-native-resize`, a window whose rule
  names a `size` is asked for that size as it appears
  ([Window sizing actions](#window-sizing-actions)), and no picture of it is
  drawn while that is in progress. Its opening waits for it too, as
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
  with its several lines run into one, or the first warning followed by
  ` (+N more)`. It goes when a later load is clean. The bar is a picture only:
  a click on it reaches whatever is beneath. The status line still says the
  same, with the path.

What plays nothing, by upstream's rules or by this port's:

- the windows the launch pass puts on the canvas, a window that takes its own
  saved slot back at any time (a minimized window shown again, a capture that
  recovered), and a window attached from the chooser: none of them opened
  here. Without Screen Recording access or with `--manual` nothing ever opens;
- a close or a dismissal that no display was drawing, a window that never had
  a picture, and everything at `animation_speed = 1`;
- under `--experimental-native-resize`, the close of a window whose picture
  was being withheld when it went (its size was still owed, or the last
  resize left it unsettled): there is nothing to fade from;
- a move, a resize, a fit and fullscreen, which upstream also animates at
  `animation_speed`: none of them exists here.

Limits the owner will notice or should know of:

- A new window is invisible until its first picture, for up to a second, and
  takes clicks at its place meanwhile. One that is being resized to its
  rule's `size` (the experimental flag only) is invisible for as long as
  that takes and a second more at most; a click at its place is taken or
  refused as for any window being resized, whether or not it is drawn.
- A problem in the config file is shown twice, in the bar and in the status
  line; one about bindings that could not be registered is the status line's
  alone, as before.
- With several warnings, which one is "first" is the parser's order. For
  unknown actions in `[keybindings]` that order is not stable from one load of
  the same file to the next (the two runs of one file here named different
  ones), so the bar's line can change on a reload that changed nothing.
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

### What is not drawn, and other limits

- Move and resize animations and upstream's fullscreen handling. Blur, the
  open and close animations and the error bar are drawn
  ([above](#blur-window-animations-and-the-error-bar)).
- `[background] cache_shader` and `cache_budget_mb` are accepted and unused:
  a shader always renders live. A tile or wallpaper is a PNG or JPEG; a
  gigapixel pyramidal TIFF falls back to the dot grid with a message.
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
- An animated background keeps the 60 Hz timer running while its panel is
  open, also when other windows cover the panel completely.
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
  `cache_shader = true`, which this port accepts and ignores);
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
the frame timer itself and its 60 Hz against a display's refresh (the tools
looped by hand, and a tick there took about 25 ms with the read-back); an
animation during a camera flight; a pinned window or a widget opening or
closing through the controller; a second display; a native-resize source
closing; a config error at launch; blur over an animated background.

### What was run for effects with the pointer policy and window sizing built in

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

## Configuration

A normal run is configured exactly like DriftWM: one TOML file in upstream's
grammar decides key bindings, mouse bindings and settings. The parser, defaults
and binding tables are upstream's own code (`driftwm-core`); the controller maps
them to a Mac keyboard and the shell registers what it reports.
[CONFIG.md](../../crates/desktop/CONFIG.md) is the controller's contract and has
the complete default table.

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
  along the bottom of every display, and the status line rests on the
  first message, a count of the rest and the path,
  until a later load is clean. Notes about bindings that were skipped are
  shown once, until the next status message. Every message also goes to stderr,
  upstream's own verbatim.
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
| `super`, and `mod` while `mod_key = "super"` (the default) | the super chord: Control-Option ⌃⌥ unless `--super` says otherwise |
| `mod3` | none; such a binding is skipped with a warning |

`--super CHORD` picks the super chord at launch: a `+`-joined subset of `ctrl`,
`alt` and `cmd`. `--super cmd` gives upstream-literal chords (`mod+a` is ⌘A,
`mod+ctrl+Right` is ⌃⌘→), which takes ⌘A, ⌘W, ⌘Z, ⌘0 to ⌘4 and others away from
every application while the canvas is open. A chord the controller rejects is
reported in the status line and the default stays.

A binding that holds super together with a modifier the super chord already
contains would be indistinguishable from the binding without it, so that
modifier is displaced: `ctrl` becomes Command and `alt` becomes Command-Shift.
With the default chord `mod+ctrl+Right` is ⌃⌥⌘→ and `mod+alt+Right` is ⌃⌥⇧⌘→.
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
| ⌃⌥L | `mod+l` | `exec /usr/bin/pmset displaysleepnow`, standing in for upstream's `spawn swaylock -f -c 000000 -kl` (see [Linux-only default commands](#linux-only-default-commands)) |
| ⌃⌥Q | `mod+q` | `close-window`: close the focused window, or dismiss a focused placeholder |
| ⌃⌥E | `mod+e` | `toggle-cursor-pan` |
| ⌃⌥T | `mod+t` | `toggle-pin-to-screen`: pin the focused window to the screen, or return it to the canvas |
| ⌃⌥⇧⌘Q | `mod+ctrl+shift+q` | `quit` |
| ⌃⌥Esc | none (the shell's own) | exit, until a binding takes the chord |

Those are 42 of upstream's 57 default key bindings. ⌥Tab and ⌥⇧Tab are taken
from every application while a canvas panel is open; rebind or unbind
`cycle-windows` in the config file to give them back. ⌃⌥⇧W is newly taken the
same way: `zoom-to-fit-snapped` used not to run, so its chord used to stay with
the applications. The rest are not registered, so their chords stay with the
applications:

- 3 whose action does not run in a default launch: ⌃⌥F
  (`toggle-fullscreen`), and ⌃⌥M and ⌃⌥⇧M (`fit-window`,
  `fit-window-snapped`). Bound in a config file they are skipped the same
  way, without a message; `Infinify msg action` answers the not-implemented
  error for each. With `--experimental-native-resize` the two fits do run, so
  ⌃⌥M and ⌃⌥⇧M are registered as well (44 of 57), and so is any key a config
  binds to `fill-window`, `grow-window` or `shrink-window`; see
  [Window sizing actions](#window-sizing-actions).
- 8 on media keys (volume, mute, brightness, play, next, previous), which macOS
  handles itself, and 4 on keys a Mac keyboard lacks (`Print`, `shift+Print`,
  `XF86AudioPause`, `XF86AudioStop`).

**Key repeat.** A held hot key whose action upstream marks repeatable
(`zoom-in`, `zoom-out`, `pan-viewport`, `nudge-window`, `cycle-windows` and
`spawn` among those that run, and `grow-window` and `shrink-window` with
`--experimental-native-resize`) fires again after `[input.keyboard] repeat_delay` (200 ms) and then
`repeat_rate` (25) times a second. It stops when the key is released, when
another hot key is pressed, when the chord's modifiers are let go, and on Return
to desktop or quit. A held `spawn` binding therefore starts its command again
on every repeat, as upstream's does, with one exception: a `spawn` whose program
is not found when the config is loaded does not repeat at all, and a command
that `sh` reports it could not find or run (exit status 127 or 126) ends the
repeat in progress and says `sh could not run: <command>` on the status line.

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

- A display's corners are the corners of its panel, that is of the whole
  display including the toolbar strip, so a pointer flicked into a physical
  screen corner counts. With `--windowed` they are the corners of that window,
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
- `disable_when_fullscreen` is read and has nothing to suppress.

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
command talks to the app that started it). It never
runs again: not on a reload, not when the list changes, not when the canvas is
reopened. If the file cannot be read or parsed at launch nothing starts, then or
later. `--windowed` runs them too, as upstream's nested backend does; the
fixture modes read no config and start nothing.

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
| ⌥ / ⌥⇧ right drag | `resize-window` / `resize-window-snapped`: only with `--experimental-native-resize`, else a status note | nothing |
| ⌥ / ⌥⇧ middle | `fit-window` / `fit-window-snapped`: only with `--experimental-native-resize`, else not implemented and the status line says so | nothing |
| ⌃⌥ middle | `toggle-fullscreen`: not implemented, the status line says so | nothing |
| ⌃⌥ left drag | pan (`mod+left`) | pan |
| ⌃⌥ two-finger scroll / wheel | pan / zoom (`mod+trackpad-scroll`, `mod+wheel-scroll`) | pan / zoom |
| ⌃⌥⌘ left drag | `center-nearest` by pointer swipe (`mod+ctrl+left`): one step to the nearest window the way the drag pulls the canvas, taken 16 points from the press | the same |
| anything else | the application's; a press focuses the window first | nothing |

A move or resize binding pressed on a widget starts no gesture, and the status
line says why for two seconds; the widget then gets the press as a plain
click, as upstream's does. On a screen-pinned window the move binding drags
the window in screen space, and a resize binding starts no gesture, says why,
and is not passed to the application
([Window rules](#window-rules-widgets-and-pinned-windows)).
Over a live window the lookup also names that window: a binding its
`pass_mouse` rule claims is not run, and the press or scroll goes to the
application as an unbound one
([Passing keys and presses](#passing-keys-and-presses-to-an-application)).
A resize binding picks its edges from the pointer's place in the window, a 3×3 grid whose centre resizes from the
bottom right, as upstream's resize grab does. A mouse binding that names an
action first focuses the window under the pointer, a placeholder included, then
runs the action. A press bound to move or resize a window does not focus it,
where upstream's does; a move by [trackpad gesture](#trackpad-gestures) does
focus and raise its window, as upstream's. After a
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
moved window keeps the 60 Hz frame timer running
(`needs_frames`), `dirty` saves the scene, a focus request (a move's, or that
of a window navigation action the gesture fired) goes to the navigation
coordinator like the request of any other reply
([What focusing does natively](#what-focusing-does-natively)), and the status
line shows what a
threshold gesture fired (`Home`, `Zoom to fit`), the refusal of an action that
does not run here yet, and the note of a gated resize.

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
canvas. `resize-window` by gesture is gated and says so.

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
  upstream's resize and shows the gated note.
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
| `[navigation] resize_step` | the step of `grow-window` and `shrink-window` (20), which run only with `--experimental-native-resize`; see [Window sizing actions](#window-sizing-actions) |
| `[zoom] step`, `mouse_speed` | a bound wheel zooms by `step ^ (lines / 2 × mouse_speed)`, animated |
| `[zoom] trackpad_speed` | scales a pinch that zooms, of two fingers or more (1.0 by default) |
| `[snap] enabled`, `gap`, `distance`, `break_force`, `corners`, `centers` | the logical window drag and its cluster |
| `[snap] outer_gap`, `focus_placement`, `[[outputs]] focus_placement` | where window navigation and `send-to-output` park a window; an `[[outputs]]` entry is matched by display UUID, `windowed`, or `*`. With `--experimental-native-resize`, `outer_gap` is also the inset of `fit-window` and `fill-window`, and `[snap] gap` the clearance `fill-window` keeps from other windows |
| `[[outputs]] hot_corners` (`top_left`, `top_right`, `bottom_left`, `bottom_right`, `threshold`, `disable_while_dragging`) | [hot corners](#displays-hot-corners-layouts-and-autostart) |
| `autostart` | commands run once at launch |
| `[session] restore_camera`, `restore_bookmarks` | what a restart restores, see [Persistence](#persistence-and-lifecycle) |
| `window_placement` | where a window that appears by itself is placed: `center`, `cursor` or `auto` |
| `[zoom] reset_on_new_window` | whether the camera's flight to a new window lands at 1:1 |
| `[navigation] auto_navigate_on_close` | whether the camera flies to the window that takes the focus after a close, when that window is docked to the closed one or overlaps it and is not wholly in view |
| `[session] suspend_on_close`, `restore_windows`; the same two keys of a `[[window_rules]]` entry, matched by bundle identifier as `app_id` and by `title` | whether a window that closes by itself leaves a stand-in; whether a saved slot whose window is gone stays as one after a discovery pass, at launch or when the canvas reopens. See [Managed windows](#managed-windows) |
| `[[window_rules]] app_id`, `title`, `position`, `widget`, `pinned_to_screen`, `output`, `focus_on_open`, `opacity` | per-window policy for a window that appears, see [Window rules](#window-rules-widgets-and-pinned-windows) |
| `[[window_rules]] pass_keys`, `pass_mouse` | the key bindings a focused window takes from Infinify, and the mouse bindings the window under the pointer takes, see [Passing keys and presses](#passing-keys-and-presses-to-an-application) |
| `[background] type`, `path`, `texture`, `mirror_tile`, `transparent_shader`, `animate_fps` | the canvas behind the windows: DriftWM's dot grid, a GLSL shader (upstream's `extras/wallpapers` work as they are), a tiled image, a wallpaper fixed to the view, or nothing. A leading `~/` in a path is expanded. PNG and JPEG only. `cache_shader` is accepted and changes nothing: a shader always renders live, which draws the same picture. See [Rendering](#rendering) |
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
not exist here: `[navigation] touch_speed` (and `resize_step` in a launch
without `--experimental-native-resize`), `[zoom] touch_speed`,
`[input.keyboard]
layout`, `variant`, `options`, `model`, `remember_layout_per_window`, `num_lock`
and `caps_lock` (macOS owns the input sources and the lock keys), the rest of
`[input.trackpad]` (macOS owns the device), `[input.mouse]`, `[input.touch]`,
`[input.tablet]`,
`[cursor]` (theme and size reach only the environment of a run command),
`[background] cache_budget_mb`, `[backend]`,
the rest of `[output]`, `[[outputs]]` `scale`, `transform`, `position` and
`mode` (macOS owns the display arrangement) and
`hot_corners.disable_when_fullscreen`, the rest of `[[window_rules]]`
(`fullscreen`, `preserve_aspect_ratio` and `layer_order` are kept with the
window and change nothing, and so is `size` in a default launch),
`[touch.*]`, `[mouse] resize_on_border` and the decoration settings, and
tap-modifier bindings (a bare `alt+shift`), which are reported and skipped.

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
reports the pointer while cursor edge pan asks for it, and keeps its 60 Hz
frame timer running for as long as the controller reports motion: a flight, a
drift, an edge pan or a cursor pan alike. Each frame is the navigation
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
  any hot key, toolbar button, hot corner, gesture-fired action or `Infinify
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
- A view's edge is the edge of its output, which begins 64 points below the top
  of the screen, under the toolbar strip. Pushing the pointer against the top
  of the screen therefore pans nothing; the top zone is the 20 points below the
  strip.
- While nothing moves the pointer is looked at about every 80 ms, so a cursor
  pan can start that late. Once it runs it is checked every frame.
- Edge pan speeds are per frame, as upstream's are, and the frame timer is
  60 Hz whatever the display's refresh rate.
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
dropped on reload, on Return to desktop, and whenever a display change recreates
the panels. Reloaded windows are unbound placeholders: one slot for every window
that was on the canvas at the save. While the app manages windows, a running
window takes its slot back by bundle identifier and title, never by PID or
window number, and the slots left over are dropped after each discovery pass
unless `[session] restore_windows = true` keeps them as stand-ins; a slot
whose titled window still exists off screen is kept, and nothing is decided
while the config file is refused
([Managed windows](#managed-windows)). With `--manual`, or without Screen
Recording access, nothing is matched and nothing is dropped: a chooser selection
is required to rebind. A failed load blocks
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
the centre of the view (the output below the toolbar strip), a window position the
centre of its frame in whole points, and a bookmark the point under the centre of
the view's usable area. The app registers no usable area yet, so that is the whole
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
After Return to desktop every request answers `the
canvas is closed`, after a failed scene load the load error, and while an
experimental native resize is unresolved `a native resize is pending`. That
last refusal is for a resize the pointer began and for any resize left
uncertain; while the size a [sizing action](#window-sizing-actions) asked for
is on its way, requests are answered as usual.

| Command | What it does now |
| --- | --- |
| `state` | Camera, zoom, the keyboard layout (the selected input source's name and short code), windows (id, bundle id as `app_id`, title, centre position, size, `is_widget`, `suspended` for a detached placeholder, and `mode`: `Normal`, or `Fit` or `Fill` while a [fit or fill](#window-sizing-actions) can still be undone; the readable form prints neither of those two, `--json` both), `pinned` (each screen-pinned window with its display and its `position` and `size` in `pinned_to_screen` rule coordinates; such a window is not under `windows` and has no `mode`), outputs (stable id as `name`, `active`) and the active bookmark. `fullscreen` and the layer lists are always empty. |
| `subscribe` | Keep the connection and print the state now and again after every change, until the app exits. See [Event stream](#event-stream). |
| `layout [--short]` | The selected keyboard input source: its name, or with `--short` its first language code. Empty until the app has reported one, which it does at launch. |
| `camera [X Y]` | Read the view centre, or fly the camera there at the current zoom. |
| `zoom [LEVEL]` | Read the zoom, or animate to a level about the view centre. The level is clamped to the range the zoom shortcuts use and the reply is the level applied. |
| `focus [APP_ID] [--id N]` | Read the focused window. Setting makes a window the logical focus and, unless it is already wholly in view, flies the camera to it as upstream does: at 1:1 for a window with a bound source (at the current zoom with `[zoom] reset_on_activation = false`), at the current zoom for a detached placeholder. A pinned window is focused and raised with no flight; a widget, which only `--id` reaches, answers `window #N is a widget and cannot be focused`. For a window with a bound source the app also performs the controller's focus request on the native window when native focus is allowed (see [Window navigation and native focus](#window-navigation-and-native-focus)); that has not been run. |
| `move [X Y] [--id N]` | Read a window's centre, or move the logical window there (whole points). The native window is not touched. A move is refused while a gesture is active, when it would put the frame outside the 32-bit integer range every other request reads positions in, and for a pinned window (`this window has no canvas position to move: …`); a pinned window reads as the canvas point its pin shows. It is the one way to move a widget. |
| `resize [WIDTH HEIGHT] [--id N]` | Read the size. Setting one answers an error (`resize is not implemented on macOS yet: native layout resize is not available`) unless the app was started with `--experimental-native-resize`; a pinned window and a widget answer upstream's `this window has no canvas size to set: …` either way. With the flag it asks the native window for that size, keeps the window's centre where it is and answers with the size asked for, not the size the window ends up with; a detached placeholder is refused. See [Window sizing actions](#window-sizing-actions); no real window has been resized this way yet. |
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
`fit-window`, `fit-window-snapped`, `fill-window`, `grow-window <direction>`
and `shrink-window <direction>` run only in an app started with
`--experimental-native-resize` ([Window sizing actions](#window-sizing-actions));
otherwise they are among the not-implemented ones below. Over the socket `cycle-windows` is always one
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
- After Return to desktop subscribers stay connected and receive nothing until
  the canvas is open again; a new `subscribe` is then refused like every other
  request. Before the canvas first opens a `subscribe` is accepted and its
  first line has no active output.

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
nested winit backend. Instead of one full-screen floating panel per display it
opens the canvas immediately in one ordinary-level, non-activating panel with a
single output whose stable id is `windowed`. No global hot keys are registered, so
use the toolbar, the pointer and `Infinify msg`; the chooser is not shown at
launch but stays reachable from the toolbar. With Screen Recording access it
manages windows like a normal run unless `--manual` is given; without, the
canvas still opens and says that it manages nothing
([Managed windows](#managed-windows)). It is rejected in `--source`,
`--demo`, `--demo-probe`, `--demo-probe-guard` and owned-resize modes. It saves to
the default scene file, takes the default socket and reads the default config
file unless `--state`, `--socket` and `--config` say otherwise, so give a
development window its own when you also use Infinify normally. Pointer
bindings and settings from the config apply; key bindings are read but not
registered. `autostart` commands run, as they do under upstream's nested
backend, and hot corners bound for `windowed` or `*` are the corners of this
window while it is the window under the pointer. A size must be at least 960x480 (the width that keeps the toolbar and
status line visible) and at most 16384 in each direction, or the app exits 64; the
panel is then clamped to the main display's visible area and centred on it. It is
the same borderless panel as the full-screen ones: it cannot be dragged, it closes
only through Return to desktop or Quit, and a display change rebuilds it. Window
navigation and native focus run here as in any normal run; with no hot keys,
cycling is the toolbar's Previous and Next or `msg action cycle-windows …`, one
committed step each.

Launched on 2026-10-09 as `--windowed 1100x700` with `--state`, `--config` and
`--socket`: `msg state` reported one output named `windowed` of 1100x636 (the
panel less its 64-point toolbar strip), and its camera was saved under that
name. The next launch, with no config file, did not restore it
(`session.restore_camera` is off by default) and started at a new output's
pose. The panel itself, its window level, the toolbar and the absence
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
world geometry. Cross-boundary pointer capture, context-menu/popover
capture, native drag-and-drop, and application-specific floating child windows
are not implemented. Pointer motion with no button down is forwarded to the
application under it, but has never been delivered to a real one, and the
cursor stays the canvas's own whatever that application would show. Right and middle clicks are forwarded through the
per-window route but have never been delivered to a real application. Ordinary selected app activation
works with the tested native window in the fixture modes; a normal run's click
now focuses through the focus driver instead, which has not been exercised, and
choosing among multiple native windows of one application and app-specific
focus rules needs broader validation.
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
leg or pointer warp). Configuration covers key bindings, mouse bindings and the
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
Media keys, tap-modifier bindings, touch-screen
gestures (`[touch.*]`), and every setting whose feature is absent are read and unused.
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
gesture bindings name three actions that do not run in a default launch
(`fit-window` and `fit-window-snapped`, which run with
`--experimental-native-resize`, and `toggle-fullscreen`, which does not run at
all), its two resize gestures are gated, and an unbound gesture
is not forwarded to the application under it. The gestures that reach window
navigation (the four-finger swipe and hold, and any `cycle-windows` a config
binds) have run only as synthetic event streams against the controller.
Three of upstream's default key bindings and three of its default mouse
bindings (window actions: `toggle-fullscreen`, `fit-window` and
`fit-window-snapped`) do not run in a default launch, and its two resize
bindings need the experimental flag. That flag also turns on `fit-window` and
`fit-window-snapped`, two of those three keys and two of those three mouse
bindings, with the other sizing actions; none of them has resized a real
window yet, see [Window sizing actions](#window-sizing-actions). Window
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
The IPC surface is a subset of DriftWM's. Six upstream actions parse but are
not implemented in a default launch (`grow-window`, `shrink-window`,
`toggle-fullscreen`, `fit-window`, `fit-window-snapped`, `fill-window`), and
with `--experimental-native-resize` only `toggle-fullscreen` is left;
`resize` is read-only unless the app runs with that flag. An IPC
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

- `--experimental-native-navigation` is still accepted and does nothing: what
  it used to gate is now the default. It is still rejected (exit 64) together
  with `--source`, `--demo-probe` and `--demo-probe-guard`, and no longer adds
  anything to `--demo`.
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
| ⌃⌥C, toolbar Center | `center-window` | Flies to the focused window, or with none to the window nearest the middle of the view, and focuses it, at 1:1. |
| ⌃⌥X | `focus-center` | The same for the topmost window under the pointer; over empty canvas, nothing. |
| ⌥Tab / ⌥⇧Tab, toolbar Next / Previous | `cycle-windows forward` / `backward` | One step through the windows in most-recently-focused order, flown to at the current zoom. |

"Window" in all four means a window on the canvas: a
[widget or a screen-pinned window](#window-rules-widgets-and-pinned-windows)
is never picked, as upstream picks neither.

The chords are DriftWM's defaults under the default super chord; a config file
rebinds them like any other key. Center, Previous and Next are on the toolbar of
every normal run, `--windowed` included, and not in the fixture modes. Hot keys
act on the display under the pointer, toolbar buttons on their own display, and
every one of them goes through the same `action` command as
`Infinify msg action`, with the pointer's position and whether a modifier is
physically down added by the shell. A [trackpad gesture](#trackpad-gestures)
bound to one of these actions runs it through the same dispatch: the pointer is
where the gesture began, and whether a modifier is down is read as the gesture
fires.

`center-window` is upstream's `RestoreFillElseReset`, and `focus-center` the
same: a window still filled by `fill-window` is flown to at the camera and
zoom its fill ran in, and any other at zoom 1. A pick-mode click does the same
for a filled window whose fill view is at or above `[zoom] interact_min`. A window can only be filled in
an app started with `--experimental-native-resize`
([Window sizing actions](#window-sizing-actions)); in a default launch there
is never a stored view to restore and both actions always reset the zoom to 1.

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
from the toolbar's Previous and Next and from `msg action cycle-windows …`,
which are never held. Any other action ends an open cycle first, committing it,
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
While the 60 Hz frame timer of [Camera motion](#camera-motion) runs, each of
its frames carries the motion that is waiting, ahead of cursor edge pan's
pointer report and the tick. That timer is also the one an animated
`[background]`, or a window that opens or leaves, keeps running
([Rendering](#rendering)); its frames then tick
nothing and still carry the waiting motion and the report. While no frame
timer runs, a timer of the hover's own
sends it, a sixtieth of a second after the last one at the earliest. Where the
pointer is has one reading for both, taken when the hover is sent and not from
the event: the pointer's position, and the output it is on, which is an output
only where a click at that point would land on that panel, so not on the
toolbar strip and not under the chooser, a menu or, in a windowed run, another
application's window.

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
  validation), at most 60 times a second while the pointer moves over a window.
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
  clicks and motion go on as above the threshold (that last part follows from
  the rule here, see
  [POINTER.md](../../crates/desktop/POINTER.md#differences-from-upstream)).
  A press on a target with any button focuses and
  raises it and is never forwarded, unless a binding whose modifiers are held
  claims the press (Option-drag still moves, Control-Option-drag still pans).
  It is a press like any other first: it ends an open cycle and a trackpad
  gesture in progress and stops every flight and drift. A
  left click released on the same display flies to the window at 1:1 (`pick`),
  which leaves pick mode (a window filled by `fill-window`, which needs
  `--experimental-native-resize`, goes back to the view it was filled in
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
  `focus_placement` says. With `--experimental-native-resize` the orange
  handles are not drawn and take no press on a display in pick mode, as
  upstream's pick sits ahead of every resize border: a press where one would
  be is the window's pick-mode press, or a press on empty canvas where the
  handle would hang outside the frame. The
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

Not done: upstream shows a pointing-hand cursor over a pick target, and the
cursor of the application under the pointer. The cursor here stays the
canvas's arrow.

### What has been run for the pointer policy

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
`--no-native-focus` was not given. Access is re-read twice a second, so a grant
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

Twice a second, when Accessibility access exists, the shell reads which window
the frontmost application has focused. If that is a window on the canvas and
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
- A press bound to move or resize a window does not focus it, where upstream's
  does (a trackpad move gesture does).
- Hover, `focus_follows_mouse`, pick mode and the pointer form of
  `center-nearest` (upstream's ⌃⌥⌘-drag swipe; its trackpad form is the
  four-finger swipe) have never been tried with a real pointer, see
  [Pointer motion, sloppy focus and pick mode](#pointer-motion-sloppy-focus-and-pick-mode).
  What will differ from DriftWM even when they work: the cursor stays the
  canvas's arrow (no pointing hand over a pick target, no application cursor);
  an application is not told when the pointer leaves its window; sloppy focus
  raises the real window natively although the canvas does not restack; a
  window enters the Option-Tab order when its focus request is answered, not
  at the hover; a held Option-Tab cycle stops sloppy focus instead of being
  ended by it; a trackpad gesture in progress, and a scroll for the 50 ms
  before its drift launches, keep focus and motion from following the pointer,
  where upstream's hover runs on; a pick lands at 1:1 in every default launch,
  where no fill view exists to return to (behind
  `--experimental-native-resize` a filled window returns to its fill view, if
  that view is at or above the threshold); pick mode is per display.
- Fullscreen and modal windows do not exist here, so none of upstream's
  special cases for them apply; a fitted or filled window exists only behind
  `--experimental-native-resize`, and the filled window's view restore above
  is the one navigation case for them that was brought over, for
  `center-window`, `focus-center` and a pick. A widget or a screen-pinned window
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
normal run. The others end by giving a real window a new size. That goes
through the [experimental native resize](#experimental-native-resizing) below
and nothing else, so they exist only in an app started with
`--experimental-native-resize`.

**No real window has been resized by any of this.** The policy has run in
controller scenarios in which the test plays the native side, and the built app
has been driven over its socket only as far as the answers a detached
placeholder gets. [What has been run for sizing](#what-has-been-run-for-sizing)
has the detail.

### The flag

| Launch | What runs |
| --- | --- |
| default | `zoom-to-fit-snapped`. Everything else in this section answers exactly as it did before this work: `action not implemented on macOS yet: <name>`, and for `msg resize WIDTH HEIGHT` `resize is not implemented on macOS yet: native layout resize is not available`. Keys bound to those actions are not registered. |
| `--experimental-native-resize` | also `fit-window`, `fit-window-snapped`, `fill-window`, `grow-window`, `shrink-window` and `msg resize WIDTH HEIGHT`, beside the orange handles the flag already turned on; and a [window rule](#window-rules-widgets-and-pinned-windows)'s `size` is asked of a new window that matches it. |

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
| `Infinify msg resize WIDTH HEIGHT [--id N]` | IPC resize | flag | Asks one window for that size and keeps its centre. The reply echoes the size asked for. |

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
  rule is placed at its own size, and its attach reply then starts the same
  size transaction for the rule's size, around the centre it was placed at.
  The first of several such windows that appear while a size is on its way is
  asked and the others keep their size (`rule.not_applied` in the snapshot
  still names `size` for them), at launch too; so does a window that maps
  during a drag. A widget, a pinned window, a window that takes over a saved
  slot and a window attached from the chooser are never asked.

### What changes for someone who used the previous build

In a default launch:

- ⌃⌥⇧W is now a registered global hot key while a canvas panel is open
  (`zoom-to-fit-snapped`), where the chord used to stay with the applications.
  Unbind it in the config file (`"mod+shift+w" = "none"`) to give it back.
- Control-Option with a four-finger pinch in now frames the focused window's
  cluster, where it showed a not-implemented note.
- Nothing else: the five sizing actions and the `msg resize` write answer
  byte for byte as before, which a controller test compares against the
  replies captured from the previous tree, and which the built app showed over
  its socket.

With `--experimental-native-resize`:

- ⌃⌥M and ⌃⌥⇧M are registered global hot keys, and Option-middle-click or
  Option with a two-finger pinch on a window now asks that real window to
  change size.
- An action or a `msg` request that arrives while a sizing action's size is on
  its way reaches the controller. For a resize the pointer began they are
  still dropped, or answered `a native resize is pending`, and an action still
  cancels it, as before.
- A press on the canvas during a sizing action's transaction is dropped
  without cancelling it.
- A config whose window rule names a `size` now asks a matching new window to
  take that size; before, and still without the flag, the size was only
  recorded. Such a window is first drawn, growing and fading in, when that
  request has been answered
  ([window animations](#blur-window-animations-and-the-error-bar)).

### Limits of sizing

- **Unproven on a real window.** Everything in "With the flag, by the code"
  above is controller scenarios and compiled, read shell code. No Accessibility
  size change has been made by a sizing action, and none of the native resize
  path's own open questions (below) is answered by this work.
- One window at a time. Upstream sizes any number of windows at once; here
  there is one transaction, and a second sizing action is continued, replaced
  or refused as described, never queued.
- A native window's minimum and maximum size are unknown before asking. The
  request is sent as computed and the window clamps it; for a fit that leaves
  the window at the fit's top-left with the size it accepted.
- A sizing action's transaction skips the check a handle drag makes before it
  begins, that the window's own extent still equals the observed one. The
  driver's root-only guard before the size change, and the controller's
  comparison of the first read with the committed size, stand in for it.
- A window resized in its own application keeps its old size on the canvas in
  a flagged run, as before, so a sizing action on it fails as described.
  Nothing in this work brings the canvas frame back in line with such a
  window.
- Escape cancels a sizing action's transaction from any application, since the
  monitor is global; whether that monitor fires at all is as unproved as it is
  for a handle drag.
- Quitting while a size is owed waits for the window's answer (`Quit pending:
  waiting for native resize result`), as for a handle drag.
- A window that appears by itself begins a size transaction from its own
  attach reply only for a window rule's `size`; the shell hands that reply to
  the same hook as an action's, before it starts the window's capture. No
  rule has matched a window in the app, so this is compiled and read only. A
  window attached from the chooser is never asked.
- A widget and a screen-pinned window are never sized: not by an action, not
  by `msg resize`, not by a rule. Upstream sizes a pinned window in screen
  space and applies a rule's `size` to both.
- The shell tells the controller it can resize on the flag alone, before the
  canvas, and so the resize coordinator, exists. No window has a live source
  until the canvas is open, so no transaction can begin in between.
- Fullscreen is not here: `toggle-fullscreen` still answers not implemented.

### What has been run for sizing

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

## Experimental native resizing

`--experimental-native-resize` independently enables eight orange handles on the
selected ordinary source, and since the sizing milestone also DriftWM's
[sizing actions](#window-sizing-actions), which run the same transaction
without a drag. Handles use true projected world edges; viewport clipping
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
