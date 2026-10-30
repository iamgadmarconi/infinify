# Windows module

What the shell does with native windows: which ones it manages, how it follows them, and the window rules, widgets and pinned windows it applies (code in `native/app/Windows` and `Desktop+Windows.m`). The parity contract, [docs/parity/README.md](../../../parity/README.md), keeps what this document describes at `implemented_unverified` or below.

## Managed windows

In DriftWM every toplevel is managed from the moment it exists. This is that
rule for native Mac windows: the app finds the ordinary windows itself, places
them, follows their titles and lets them go when they close. The decisions are
the controller's and are upstream's; [LIFECYCLE.md](../../../crates/desktop/LIFECYCLE.md)
is the contract and lists every difference. The parity contract keeps the rows for this section at `implemented_unverified` ("Some rows still contain known partial behavior; that status is not a claim that only testing remains", [What is still open](../../../parity/README.md#status)).

**At launch.**

- With Screen Recording and Accessibility access: no chooser. The canvas opens
  at once on every display and the app starts managing.
- With either missing: the permission window of [Desktop mode](../../user-guide.md#desktop-mode),
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
[native focus is followed](../Navigation/README.md#native-focus-is-followed) in every normal run, and
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
walks ([Window navigation and native focus](../Navigation/README.md#window-navigation-and-native-focus)):
a click in the canvas, a new window, `msg focus` or a followed native focus
enters it once the real window's focus is confirmed, or at once when the app
performs no native focus (no Accessibility access, or `--no-native-focus`). A
drag in progress on another window goes on, and then no camera flies. A window counts as closed when its
window number is gone from the system's window list or its process is gone,
and, where [the events are in place](#event-driven-tracking), also when its
application has reported it destroyed and it is no longer on screen; a
capture stream that fails while the window is still there keeps the old
behaviour, a detached placeholder, which only a `--manual` run's chooser can
rebind ([Desktop mode](../../user-guide.md#limits-of-desktop-mode)).

**Titles** follow the native window and are saved, because slots are matched by
title at the next launch.

**Capture on demand.** A ScreenCaptureKit stream runs only while its window is
in view on some display. It stops about two seconds after the window left every
view and starts again when it returns; a window that returns within those two
seconds shows its last frame at once, and one that returns later shows its
last picture, which the compositor keeps ([Rendering](../Canvas/README.md#rendering)), until the
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
  ([Native focus is followed](../Navigation/README.md#native-focus-is-followed)).
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
  ([Rendering](../Canvas/README.md#rendering)), and so is every other detached placeholder; the
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
  application (`DWWindowManager.m` `-pass:`, `DWWindowEvents.m` `-add:`).
- The one place a native window is bound, `-attach:logical:world:placed:` in
  `Desktop+Windows.m`, refuses a process outside the scope before a source, a router or a
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
  [resize border](../Navigation/README.md#resizing-a-window-with-the-pointer) just outside a frame is
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
`tests/native/app/Windows/ScopeFixture.m` (a regular application with one titled
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

### Event-driven tracking

A managed run with Accessibility access is told about changes to native
windows, the way the yabai window manager is, and keeps asking as a slower
safety net. There is no flag, no control and no extra permission for it: it is on whenever the app manages windows (Screen
Recording access, no `--manual`), the per-application observers need
Accessibility access, and it uses
public Accessibility and `NSWorkspace` API plus the one private call the
window test already used (`_AXUIElementGetWindow`). The parity contract keeps the rows for event-driven tracking at `implemented_unverified` ("Some rows still contain known partial behavior; that status is not a claim that only testing remains", [What is still open](../../../parity/README.md#status)).

What is observed (`native/app/Windows/DWWindowEvents.m`, with `DWWindowEvents+Applications.m` and `DWWindowEvents+Observation.m`):

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
| application activated; focused window changed | native focus is read through the same path as the focus poll ([Native focus is followed](../Navigation/README.md#native-focus-is-followed)) |

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
  (`-destroyed:info:` in `Desktop+Windows.m`, the `kCGWindowIsOnscreen` test); without it
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
[RULES.md](../../../crates/desktop/RULES.md) is their contract with every
difference from upstream. The parity contract keeps the rows for window rules, widgets and pins at `implemented_unverified` ("Some rows still contain known partial behavior; that status is not a claim that only testing remains", [What is still open](../../../parity/README.md#status)).

**What a config can do.**

- ⌃⌥T (`mod+t`, `toggle-pin-to-screen`) is a registered global hot key in
  a normal run, taken from every application while a canvas is open.
  `"mod+t" = "none"` under `[keybindings]` gives it back.
- `[[window_rules]]` entries act on each window
  as it appears: `position`, `widget`, `pinned_to_screen`, `output`,
  `focus_on_open` and `opacity`, and its `decoration`, border, corner and
  shadow keys change how the window is drawn ([Rendering](../Canvas/README.md#rendering)).
  `[decorations] opacity` and `opacity_focused` dim windows too.
- `Infinify msg pin`, `msg opacity`, `msg action toggle-pin-to-screen` and
  `msg action move-to-bookmark NAME` run.
  `msg move` and `msg resize` refuse a pinned window, `msg focus` refuses a
  widget, and `msg state` lists a pinned window under `pinned`, not under
  `windows`.
- The scene file has a `pins` field while a window is pinned
  ([Persistence](../../user-guide.md#persistence-and-lifecycle)).

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
  [the gaps were closed](../../user-guide.md#upstream-behaviour-gaps-closed) the press raises
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
| `decoration`, `border_width`, `border_color`, `border_color_focused`, `corner_radius`, `shadow` | what the window is drawn with in place of the `[decorations]` values, see [Rendering](../Canvas/README.md#rendering) |
| `suspend_on_close`, `restore_windows` | see [Managed windows](#managed-windows) |
| `size` | a new window is placed for that size, as upstream places it, and asked for it as it appears, a widget and a window the rule pins included: `position` is the centre of the size named, and a pin and the placement policy take that frame too. Several such windows that appear together are asked one after another, in the order they appeared ([Window sizing actions](../Navigation/README.md#window-sizing-actions)). A window that takes over a saved slot is never asked. With `fullscreen = true` beside it the window is placed for that size all the same and is asked for it only when it leaves fullscreen. Run on a fixture window (`tests/e2e/scoped-sizing.sh`); no rule has resized an application of the owner's |
| `fullscreen` | a new window whose rule says `fullscreen = true` enters DriftWM's [fullscreen](../Navigation/README.md#fullscreen) once it is placed, on the display `output` names when that one is connected, else on its pin's, else on the active one; a widget, a window that takes over a saved slot, a window attached from the chooser and a window that was already open when the app started are never made fullscreen by a rule. No rule has made a real window fullscreen |
| `blur = true` | what lies beneath the window is frosted, whatever `[decorations] blur` says, also while the window is fullscreen, see [Blur, window animations and the error bar](../Canvas/README.md#blur-window-animations-and-the-error-bar) |
| `pass_keys = true` or a list of key combos | while the window holds the keyboard, those key bindings are not Infinify's: the chord reaches the application, [below](#passing-keys-and-presses-to-an-application) |
| `pass_mouse = true` or a list of mouse combos | a press or scroll over the window that one of those bindings would take goes to the application as an unbound one, below |
| `layer_order = N` | kept with the window and ignored, as upstream ignores it for a regular window, [below](#layer_order) |
| `preserve_aspect_ratio` | kept with the window; nothing is constrained for it |

A file with a key the grammar does not know inside a rule is refused whole with
upstream's TOML error (`unknown field …`), and the previous configuration stays
in force. A rule with neither `app_id` nor `title`, an unknown `decoration`
mode or a non-positive `size` is a warning on stderr and in the
[error bar](../Canvas/README.md#blur-window-animations-and-the-error-bar),
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
([RULES.md](../../../crates/desktop/RULES.md#navigation-activation-gestures-and-outputs)),
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
  The resize swipe [resizes a canvas window](../Navigation/README.md#resizing-a-window-with-the-pointer) at the controller and is claimed
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
([RULES.md](../../../crates/desktop/RULES.md#pass-rules)); the shell only stops
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
  ([pick mode](../Navigation/README.md#pointer-motion-sloppy-focus-and-pick-mode)) a window on the
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
