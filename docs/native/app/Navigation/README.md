# Navigation module

How the shell moves the camera and the focus: camera motion, window navigation and native focus, window sizing, the pointer resize and fullscreen (code in `native/app/Navigation` and the `Desktop` categories that call it). Beside this file are [NATIVE-FOCUS.md](NATIVE-FOCUS.md) and [NATIVE-RESIZE.md](NATIVE-RESIZE.md), the two Accessibility adapters. The parity contract, [docs/parity/README.md](../../../parity/README.md), keeps what this document describes at `implemented_unverified` or below.

## Camera motion

A normal run moves the camera the way DriftWM does: a flick drifts, a window
dragged to the edge pans the canvas under it, a pointer pushed against an edge
can pan the view, and the pointer's pan and zoom speeds come from the config.
The physics and the numbers are the controller's
([MOTION.md](../../../crates/desktop/MOTION.md)): momentum is upstream's own
`MomentumState` from `driftwm-core`, and edge pan, cursor edge pan and the
pointer zooms are adapted from the pinned upstream source. The shell only says
when and where. It stamps each pan with its event's time and source, tells the
controller when a pan ends, passes the pointer along with a window drag,
reports the pointer while cursor edge pan asks for it, and keeps its frame
timer running for as long as the controller reports motion: a flight, a
drift, an edge pan or a cursor pan alike. The frame timer is a display link
at the display's refresh rate ([Rendering](../Canvas/README.md#rendering)), 120 Hz on a ProMotion
display. Each frame is the navigation
coordinator's tick, the one that flies
[window navigation](#window-navigation-and-native-focus), watches the hot
corners and, while a `msg subscribe` client is connected, is followed by at
most one [State event](../../user-guide.md#event-stream). Ahead of the tick a frame reads the
pointer once, if anything wants it, for the two things that do: the
[hover](#pointer-motion-sloppy-focus-and-pick-mode) a moving pointer has
waiting, which goes with the frame, and then cursor edge pan's report. The
same timer redraws an animated `[background]` ([Rendering](../Canvas/README.md#rendering)); kept
running by that alone it ticks nothing, and the camera and the hot corners are
the idle poll's as before, but each of its frames still reads the pointer the
same way: a waiting hover goes with a frame whenever this timer runs, whatever
keeps it running, and with a timer of its own only when it does not. A
[trackpad gesture](../Input/README.md#trackpad-gestures) needs none of that from the shell: its
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
  [Trackpad gestures](../Input/README.md#trackpad-gestures)) is scaled by `zoom.trackpad_speed`
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

## Window navigation and native focus

Every normal run (the default launch and `--state`, with or without
`--windowed`) navigates between windows as DriftWM does and tries to give the
real window native focus. The controller's rules are in
[NAVIGATION.md](../../../crates/desktop/NAVIGATION.md#window-navigation-actions)
and [FOCUS.md](../../../crates/desktop/FOCUS.md); this section says what the shell
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
[widget or a screen-pinned window](../Windows/README.md#window-rules-widgets-and-pinned-windows)
is never picked, as upstream picks neither.

The chords are DriftWM's defaults under the default super chord; a config file
rebinds them like any other key. Hot keys
act on the display under the pointer, and
every one of them goes through the same `action` command as
`Infinify msg action`, with the pointer's position and whether a modifier is
physically down added by the shell. A [trackpad gesture](../Input/README.md#trackpad-gestures)
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
[POINTER.md](../../../crates/desktop/POINTER.md).

A canvas panel is never key and its application is rarely active, so a normal
run takes pointer motion through a tracking area that is always active. The
newest motion is sent to the controller as `hover`, at most once a frame.
While the frame timer of [Camera motion](#camera-motion) runs, each of
its frames carries the motion that is waiting, ahead of cursor edge pan's
pointer report and the tick. That timer is also the one an animated
`[background]`, or a window that opens or leaves, keeps running
([Rendering](../Canvas/README.md#rendering)); its frames then tick
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
[trackpad gesture](../Input/README.md#trackpad-gestures) is recognised or in progress (a swipe,
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
  layers of [Window rules](../Windows/README.md#window-rules-widgets-and-pinned-windows): a
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
  ([POINTER.md](../../../crates/desktop/POINTER.md#screen-pinned-windows-and-widgets)).
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
  it lists ([Passing keys and presses](../Windows/README.md#passing-keys-and-presses-to-an-application)).
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
([POINTER.md](../../../crates/desktop/POINTER.md)). The shell's `-[DesktopView hit:output:]` read that reply as
`NSDictionary *hit=reply[@"hit"]`, and on the ordered path (the renderer's applied order still showed a
placement under the pointer) it subscripted it as `hit[@"window"]`. JSON null arrives as `NSNull`, which has no keyed
subscripting, so build `c49eae1` raised `NSInvalidArgumentException` inside the event tap and ended the owner's
first compositor-mode run (`-[NSNull objectForKeyedSubscript:]` in `-[DesktopView hit:output:]`, called from
`-[Desktop nativeInput:event:]`). The reply is now read through `DWControllerHit` (`native/app/Desktop/DWControllerHit.h`),
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
([Event-driven tracking](../Windows/README.md#event-driven-tracking)), at the first poll after a
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
in the [sizing contract](../../../crates/desktop/SIZES.md). One of them,
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
[readback mode](../../../crates/desktop/NATIVE_RESIZE.md#readback-mode).

**What has been resized.** Disposable fixture windows of the test's own, in a windowed run scoped to them without Screen
Recording access: `tests/e2e/scoped-sizing.sh`.
No application of the owner's has been resized by it, and no key chord has
been pressed by a test.

### When resize runs

Everything in this section runs in every normal run: `zoom-to-fit-snapped`, `fit-window`, `fit-window-snapped`, `fill-window`, `grow-window`, `shrink-window`, `msg resize WIDTH HEIGHT`, and a [window rule](../Windows/README.md#window-rules-widgets-and-pinned-windows)'s `size`, asked of a new window that matches it. Keys bound to those actions are registered where a run registers keys. A size is settled by reading the window back. There is no other switch and no config key for it.

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

## Fullscreen

DriftWM's fullscreen, as controller policy: one window takes its whole display
on the canvas, alone, and everything is put back when it leaves. The rules are
upstream's and are set out in the
[fullscreen contract](../../../crates/desktop/FULLSCREEN.md). This is **not**
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
  ([Passing keys and presses](../Windows/README.md#passing-keys-and-presses-to-an-application)):
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

## Window navigation limits

- **What enters the cycle order.** With native focus allowed, the
  most-recently-focused order holds only windows whose native focus the driver
  confirmed or the shell observed: a window whose focus request fails, or is
  overtaken by the next one before it is confirmed, is not in it, where
  upstream would have put it there. Without native focus (no Accessibility
  access, or `--no-native-focus`) every window you focus on the canvas enters
  it. A detached placeholder is never in the order (upstream's stand-ins are
  not either), so a canvas of placeholders alone cannot be cycled. The same
  order decides who takes the focus when a window closes
  ([Managed windows](../Windows/README.md#managed-windows)).
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
  ([Window rules](../Windows/README.md#window-rules-widgets-and-pinned-windows)).
- Following native focus moves the camera by itself when an application on the
  canvas takes focus while its window is clipped.
- If the controller refuses to follow a native focus change (a drag or resize
  is in progress), the focus is still recorded, the camera stays, and the
  refusal text is a status note on stderr.
