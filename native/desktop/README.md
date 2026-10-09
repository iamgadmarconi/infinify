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
world. Each visible `(logical window, display)` has its own
`AVSampleBufferDisplayLayer`; one ScreenCaptureKit stream feeds all placements of
a source. This is continuous live capture of native application content.
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
- Pan a display's camera: drag or two-finger scroll on empty canvas, or
  Control-Option-drag / Control-Option-scroll anywhere. Zoom, pointer-anchored,
  from 0.001 to 1.0: mouse wheel on empty canvas, Control-Option-wheel anywhere,
  or pinch. The view actions below are the animated toolbar and keyboard
  equivalents.
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
  and does nothing if a gesture already zoomed past that. A pointer press, a
  pinch, or a scroll that actually pans or zooms the canvas stops a flight where
  it is. A scroll that is forwarded to a window, has no delta, or is already at
  the zoom limit leaves the flight alone.
- Window navigation, in every normal run (toolbar buttons Center, Previous and
  Next; the hot keys only while panels are open and not with `--windowed`):
  Control-Option with an arrow key (`center-nearest <direction>`) focuses the
  nearest window in that direction and flies the camera to it at the current
  zoom; Control-Option-C (`center-window`) centres the focused window, or the
  one nearest the middle of the view, at 1:1; Control-Option-X (`focus-center`)
  does the same for the window under the pointer; Option-Tab and
  Option-Shift-Tab (`cycle-windows forward` / `backward`) step through the
  windows most recently focused first, and letting go of Option commits the
  choice. A click on a window gives it canvas focus and starts its native
  focus, then the click is forwarded; a click on empty canvas unfocuses, and
  focusing a canvas window in its own application (Command-Tab, the Dock) is
  followed by the canvas. Focusing means logical focus, raising in the canvas,
  and, when Infinify has Accessibility access, activating and raising the real
  window.
  [Window navigation and native focus](#window-navigation-and-native-focus) has
  the rules, the flags and what has and has not been run.
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
  cluster. Control-Option-Shift with an arrow key (`nudge-window <direction>`)
  moves the focused logical window by `navigation.nudge_step` world points.
  Neither moves a native window.
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
- Control-Option-click a detached placeholder dismisses it only while no mouse
  binding claims that press, and the placeholder shows the hint only then.
  DriftWM's defaults do claim it under the default super chord (`mod+left` pans
  anywhere), so out of the box there is no pointer way to dismiss a placeholder.
  `[mouse.anywhere]` with `"mod+left" = "none"`, or a `--super` chord other than
  `ctrl+alt`, frees the press.
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
a docked or overlapping follower that is not wholly in view. "Had the focus"
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
seconds shows its last frame at once, one that returns later shows an empty
tile until the restarted stream delivers. With `--experimental-native-resize`
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
- A stand-in looks like every detached placeholder ("Detached window N"): no
  name label, and neither a click nor Return relaunches it as upstream's do. A
  click focuses it like any window, and ⌃⌥Q then dismisses it; it is relaunched
  through `msg relaunch`; there is no toolbar button for close.
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
  error, or a value upstream's parser warns about, the status line rests on the
  first message, a count of the rest and the path, as upstream's error bar
  does, until a later load is clean. Notes about bindings that were skipped are
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
only while a canvas panel is open; `--windowed` registers none.

| Chord | DriftWM binding | Action |
| --- | --- | --- |
| ⌃⌥A | `mod+a` | `home-toggle` |
| ⌃⌥W | `mod+w` | `zoom-to-fit` |
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
| ⌃⌥⇧⌘Q | `mod+ctrl+shift+q` | `quit` |
| ⌃⌥Esc | none (the shell's own) | exit, until a binding takes the chord |

Those are 39 of upstream's 57 default key bindings. ⌥Tab and ⌥⇧Tab are taken
from every application while a canvas panel is open; rebind or unbind
`cycle-windows` in the config file to give them back. The rest are not
registered, so their chords stay with the applications:

- 6 whose action does not run on macOS yet: ⌃⌥E
  (`toggle-cursor-pan`), ⌃⌥F (`toggle-fullscreen`), ⌃⌥M and ⌃⌥⇧M (`fit-window`,
  `fit-window-snapped`), ⌃⌥⇧W (`zoom-to-fit-snapped`) and ⌃⌥T
  (`toggle-pin-to-screen`). Bound in a config file they are skipped the same
  way, without a message; `Infinify msg action` answers the not-implemented
  error for each.
- 8 on media keys (volume, mute, brightness, play, next, previous), which macOS
  handles itself, and 4 on keys a Mac keyboard lacks (`Print`, `shift+Print`,
  `XF86AudioPause`, `XF86AudioStop`).

**Key repeat.** A held hot key whose action upstream marks repeatable
(`zoom-in`, `zoom-out`, `pan-viewport`, `nudge-window`, `cycle-windows` and
`spawn` among those that run) fires again after `[input.keyboard] repeat_delay` (200 ms) and then
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
| ⌥ / ⌥⇧ / ⌃⌥ middle | `fit-window` / `fit-window-snapped` / `toggle-fullscreen`: not implemented, the status line says so | nothing |
| ⌃⌥ left drag | pan (`mod+left`) | pan |
| ⌃⌥ two-finger scroll / wheel | pan / zoom (`mod+trackpad-scroll`, `mod+wheel-scroll`) | pan / zoom |
| ⌃⌥⌘ left drag | `center-nearest` by pointer swipe: not implemented, a status note (the keyboard action runs) | the same |
| anything else | the application's; a press focuses the window first | nothing |

A resize binding picks its edges from the pointer's place in the window, a 3×3 grid whose centre resizes from the
bottom right, as upstream's resize grab does. A mouse binding that names an
action first focuses the window under the pointer, a placeholder included, then
runs the action. A press bound to move or resize a window does not focus it,
where upstream's does. After a
two-finger scroll has panned, scrolls stay with the canvas for 150 ms even if a
window slides under the pointer, as upstream. One gesture runs at a time: a
second button pressed during a gesture is ignored. Upstream's `wheel-up` and
`wheel-down` triggers are parsed but never fire, and the grammar has no name for
the back and forward buttons. Pinch is not a mouse binding and is unchanged.

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
| `[navigation] trackpad_speed` | multiplies a bound two-finger scroll pan (1.5 by default) |
| `[zoom] step`, `fit_padding` | `zoom-in` / `zoom-out`, `zoom-to-fit` and the zoom-out limit |
| `[zoom] step`, `mouse_speed` | a bound wheel zooms by `step ^ (lines / 2 × mouse_speed)` |
| `[snap] enabled`, `gap`, `distance`, `break_force`, `corners`, `centers` | the logical window drag and its cluster |
| `[snap] outer_gap`, `focus_placement`, `[[outputs]] focus_placement` | where window navigation and `send-to-output` park a window; an `[[outputs]]` entry is matched by display UUID, `windowed`, or `*` |
| `[[outputs]] hot_corners` (`top_left`, `top_right`, `bottom_left`, `bottom_right`, `threshold`, `disable_while_dragging`) | [hot corners](#displays-hot-corners-layouts-and-autostart) |
| `autostart` | commands run once at launch |
| `[session] restore_camera`, `restore_bookmarks` | what a restart restores, see [Persistence](#persistence-and-lifecycle) |
| `window_placement` | where a window that appears by itself is placed: `center`, `cursor` or `auto` |
| `[zoom] reset_on_new_window` | whether the camera's flight to a new window lands at 1:1 |
| `[navigation] auto_navigate_on_close` | whether the camera flies to the window that takes the focus after a close, when that window is docked to the closed one or overlaps it and is not wholly in view |
| `[session] suspend_on_close`, `restore_windows`; the same two keys of a `[[window_rules]]` entry, matched by bundle identifier as `app_id` and by `title` | whether a window that closes by itself leaves a stand-in; whether a saved slot whose window is gone stays as one after a discovery pass, at launch or when the canvas reopens. See [Managed windows](#managed-windows) |
| `[decorations] title_bar_height` | the diagonal step of the placement cascade, and nothing else |
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
not exist here: `[navigation] mouse_speed` (a drag pans 1:1), `[zoom]
trackpad_speed` (pinch is unscaled), `focus_follows_mouse`, `[navigation]
resize_step`, `drift`, `touch_speed` and `edge_pan`, `[zoom] touch_speed` and
`interact_min`, `[input.keyboard]
layout`, `variant`, `options`, `model`, `remember_layout_per_window`, `num_lock`
and `caps_lock` (macOS owns the input sources and the lock keys),
`[input.trackpad]`, `[input.mouse]`, `[input.touch]`, `[input.tablet]`,
`[cursor]` (theme and size reach only the environment of a run command),
`[background]`, the rest of `[decorations]`, `[effects]`, `[backend]`,
`[output]`, `[[outputs]]` `scale`, `transform`, `position` and `mode` (macOS
owns the display arrangement) and `hot_corners.disable_when_fullscreen`,
the rest of `[[window_rules]]` (`position`, `size`, `focus_on_open`, `widget`
and the others shape no window), `[gestures.*]`,
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

## Persistence and lifecycle

The default scene file is
`~/Library/Application Support/Infinify/scene.json`. `--state /absolute/file.json`
selects another file whose parent directory already exists. Saves use the Rust
controller's private temporary file, fsync, atomic rename, and directory sync.
Only world geometry, display UUID cameras, bookmarks, app/title metadata and
which placeholders are stand-ins (by logical id) are
persisted; PIDs, window IDs, process births, and captures are not saved. Bookmarks
and the stand-in list (`standins`, written only while there is one) are additive
fields of the same file and the format version is unchanged: scene
files written by older builds still load, with no bookmarks and no stand-ins. Older builds reject
fields they do not know, so an older build cannot read a scene file that contains
either; keep a copy of a scene file before opening it with an older build.
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
experimental native resize is unresolved `a native resize is pending`.

| Command | What it does now |
| --- | --- |
| `state` | Camera, zoom, the keyboard layout (the selected input source's name and short code), windows (id, bundle id as `app_id`, title, centre position, size, `suspended` for a detached placeholder), outputs (stable id as `name`, `active`) and the active bookmark. `fullscreen`, `pinned` and the layer lists are always empty. |
| `subscribe` | Keep the connection and print the state now and again after every change, until the app exits. See [Event stream](#event-stream). |
| `layout [--short]` | The selected keyboard input source: its name, or with `--short` its first language code. Empty until the app has reported one, which it does at launch. |
| `camera [X Y]` | Read the view centre, or fly the camera there at the current zoom. |
| `zoom [LEVEL]` | Read the zoom, or animate to a level about the view centre. The level is clamped to the range the zoom shortcuts use and the reply is the level applied. |
| `focus [APP_ID] [--id N]` | Read the focused window. Setting makes a window the logical focus and, unless it is already wholly in view, flies the camera to it as upstream does: at 1:1 for a window with a bound source (at the current zoom with `[zoom] reset_on_activation = false`), at the current zoom for a detached placeholder. For a window with a bound source the app also performs the controller's focus request on the native window when native focus is allowed (see [Window navigation and native focus](#window-navigation-and-native-focus)); that has not been run. |
| `move [X Y] [--id N]` | Read a window's centre, or move the logical window there (whole points). The native window is not touched. A move is refused while a gesture is active, and when it would put the frame outside the 32-bit integer range every other request reads positions in. |
| `resize [WIDTH HEIGHT] [--id N]` | Read the size only. Setting one answers an error: native layout resize is not available yet. |
| `action SPEC...` | Run an upstream action string, below. |
| `bookmark [NAME] [X Y] [--delete]` | List bookmarks, get or set one, or delete it. |
| `close [APP_ID] [--id N]` | A window with a bound source: ask its application to close it (its close button, through Accessibility); it leaves no stand-in. A placeholder: dismiss it. |
| `suspend [APP_ID] [--id N]` | A window with a bound source: focus it, close it the same way and leave a stand-in. A placeholder: `window is already suspended`. |
| `relaunch [APP_ID] [--id N]` | A placeholder: open its application by bundle identifier; the next window of that application takes the slot. Answers `ok` once the request is made, also for an application that is not installed (status line and stderr then say so). |
| `debug-counters` | A small map of controller collection sizes; the keys are Infinify's own and not stable. |

`opacity`, `pin` and `screenshot` answer
`<name> is not implemented on macOS yet`. `close`, `suspend`
and `relaunch` with no selector act on the focused window;
[Managed windows](#managed-windows) has their rules and limits.

`action` parses the full upstream action grammar with upstream's spelling: it
is the grammar the config file's bindings use. These run:
`pan-viewport <direction>`, `home-toggle`, `zoom-in`, `zoom-out`, `zoom-reset`,
`zoom-to-fit`, `center-window`, `center-nearest <direction>`,
`cycle-windows forward|backward`, `focus-center`, `go-to-bookmark NAME`,
`set-bookmark NAME`, `nudge-window <direction>`, `close-window`,
`suspend-window`, `send-to-output <direction>`,
`send-cursor-to-output <direction>`, `switch-layout next|prev|INDEX`,
`exec COMMAND`, `spawn COMMAND`, `exec-terminal`, `exec-launcher`,
`reload-config` and `quit`. Over the socket `cycle-windows` is always one
committed step, where upstream keeps the cycle open if a modifier happens to be
down, and `focus-center` uses the real pointer's position at that moment.
Every action but `cycle-windows` first ends a cycle in progress, as upstream's
does. `send-cursor-to-output` moves the real pointer and `switch-layout`
changes the selected input source, for whoever sends them. `close-window` and
`suspend-window` press the focused window's own close button. `exec` and `spawn`
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
see it land. A pointer press or pinch on the canvas, or a scroll that pans or
zooms it, stops a scripted flight where it is, like any other. A client must wait for its reply: a
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
world geometry. Hover, cross-boundary pointer capture, context-menu/popover
capture, native drag-and-drop, and application-specific floating child windows
are not implemented. Right and middle clicks are forwarded through the
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
Media keys, tap-modifier bindings, `wheel-up` / `wheel-down`, trackpad and
touch gestures, and every setting whose feature is absent are read and unused.
Six of upstream's default key bindings and four of its default mouse
bindings (three window actions and the pointer `center-nearest` swipe) do not
run here yet, and its two resize bindings need the experimental flag. Window
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
during a flight), so a pointer that crosses a corner without resting there can
be missed, and none has been fired on a live run, so the `--windowed` rule that
a covered window's corners do not fire is unrun as well. `send-to-output` and
`send-cursor-to-output` have run live only with a single display, where they do
nothing: the window move to another display and the pointer warp are unrun.
`switch-layout` has run only on a machine with one enabled input source, where
it selects nothing; selecting an input method (as opposed to a plain keyboard
layout) from this accessory app is untried. The event stream reporting the
output under the pointer becoming active, within one idle poll, is unrun: it
needs a second display.
The IPC surface is a subset of DriftWM's. Several upstream actions parse but are
not implemented; `opacity`, `pin` and
`screenshot` are not implemented; `resize` is read-only. An IPC
focus is logical focus and camera navigation, plus a native focus request for a
window with a bound source that no run has yet performed, and
an IPC move is a logical world move that never moves the native window. Nested
`--windowed` mode registers no global shortcuts and has one output.
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

### Actions

| Control | Action | What it does |
| --- | --- | --- |
| ⌃⌥ arrow | `center-nearest <direction>` | Focuses the nearest window in a 90° cone and flies the camera to it at the current zoom. The search starts at the focused window while all of it is on the display, otherwise at the middle of the view. Detached placeholders are candidates, and so are `[navigation] anchors`: landing on an anchor flies the camera there and leaves no window focused. Nothing in the cone: nothing happens. |
| ⌃⌥C, toolbar Center | `center-window` | Flies to the focused window, or with none to the window nearest the middle of the view, and focuses it, at 1:1. |
| ⌃⌥X | `focus-center` | The same for the topmost window under the pointer; over empty canvas, nothing. |
| ⌥Tab / ⌥⇧Tab, toolbar Next / Previous | `cycle-windows forward` / `backward` | One step through the windows in most-recently-focused order, flown to at the current zoom. |

The chords are DriftWM's defaults under the default super chord; a config file
rebinds them like any other key. Center, Previous and Next are on the toolbar of
every normal run, `--windowed` included, and not in the fixture modes. Hot keys
act on the display under the pointer, toolbar buttons on their own display, and
every one of them goes through the same `action` command as
`Infinify msg action`, with the pointer's position and whether a modifier is
physically down added by the shell.

`center-window` is upstream's `RestoreFillElseReset`. Infinify has no fill
yet, so there is never a stored view to restore and the action always resets
the zoom to 1.

### Cycling and hold-to-commit

A `cycle-windows` hot key (or hot corner) that fires while any of Control,
Option, Shift or Command is physically down opens a cycle that stays open: each further press
steps deeper into the order as it was when the cycle began. While it is open the
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
A newer request, a canvas press, a scroll that pans or zooms the canvas, a
pinch, opening the chooser, adding, rebinding or losing a source, Return to
desktop and a display change all withdraw a request that is still in flight.

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
  does. The pointer form of `center-nearest` (upstream's ⌃⌥⌘-drag swipe) is not
  implemented; the status line says so.
- `focus_follows_mouse` is read from the config and does nothing. Fullscreen,
  fit-window, pinned and modal windows do not exist here, so none of upstream's
  special cases for them apply.
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

Not run at all: native focus of a real window by any route; a window with a
bound source; any hot key, Option-Tab and the release that commits it; the
toolbar's Center, Previous and Next; any click, click-to-focus, the reveal at
a completed click's release, a press that ends a cycle, and the empty-canvas
unfocus; native focus being followed; the observer withdrawing a request; a
cycle that changes the order in the running app, with native focus or on
logical focus alone; the status note for missing Accessibility;
`auto_navigate_on_click` and `reset_on_activation` in the app; anything drawn;
more than one display.

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
