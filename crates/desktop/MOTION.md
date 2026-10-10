# Camera motion, ABI 1

Additive ABI 1 commands and fields make the camera move as DriftWM's does: a
flick keeps the viewport drifting until friction stops it, a window dragged to
the edge of its output pans the canvas under it, a bare pointer pushed against
an edge can pan the view, and the pointer zooms take their speeds from the
[config](CONFIG.md). The logic is adapted from malbiruk/driftwm at
`352333a8fa1b22171492d4b71a54102045c9a19d`: `src/state/viewport_animation.rs`,
`src/state/edge_pan.rs`, `src/grabs/pan_grab.rs`, the edge-pan hook of
`src/grabs/move_grab.rs`, the scroll, wheel-zoom and cursor-pan parts of
`src/input/pointer.rs` and `src/input/mod.rs`, `src/input/gestures/pinch.rs`
and the `ToggleCursorPan` arm of `src/input/actions.rs`. Momentum itself is not
adapted: it is `driftwm_core::canvas::MomentumState` and its `VelocityTracker`,
upstream's own code.

No command here performs a native operation, and none reads native geometry:
the camera and world math use world rectangles, each output's `screen_bounds`
and the navigation context's `usable_rect_local` only.

| Command | Fields | Result |
| --- | --- | --- |
| `pan` | `output`, `screen_delta`, optional `time_ms`, optional `source: finger / wheel / continuous / drag` | `{}` |
| `pan_end` | `output`, optional `time_ms` | `{needs_frames}` |
| `gesture_to` | total `screen_delta`, optional global `pointer` point | `{needs_frames}` |
| `pointer` | `output` or null, global `screen` point | `{needs_pointer, needs_frames}` |
| `zoom_by` | `output`, global `anchor` point, `delta`, `source: wheel / pinch`, optional `phase: begin / update / end` | `{navigation, needs_frames}` |
| `tick_navigation` | `timestamp_ns` | `changed_outputs`, `needs_frames`, `needs_pointer` |
| `action` `toggle-cursor-pan` | optional `output` | `{navigation: null, effects: [], dirty: false}` |

Every other command keeps its shape. `pan` without `time_ms`, `gesture_to`
without `pointer` and `zoom` do what they did, except that `gesture_to` now
answers `{needs_frames}` instead of `{}` and that `pan` and `zoom` end a coast.
A rejected command leaves all of the state below as it was.

The [trackpad gesture](GESTURES.md) commands come through the same code, so
nothing below exists twice. A gesture that pans (`swipe_pan`) makes a timed
`pan` with `source: finger` of each update and a `pan_end`, at the end event's
`time_ms`, of its end. A gesture that zooms (`pinch_zoom`) is the pinch of
[Pointer zoom](#pointer-zoom), handed upstream's scale itself. A gesture that
moves a window (`swipe_move`) drives the drag `begin_drag` installs and passes
its virtual pointer as `gesture_to`'s `pointer`.

## Timed pans and momentum

Each output has upstream's `MomentumState`, created by its first timed pan with
the config's `navigation.drift` (0.5 with no file). A reload gives a coast in
progress the new drift, as upstream's reload does.

`pan` with `time_ms` is upstream's `drift_pan_on`. `time_ms` is the input
event's own time in milliseconds on any one monotonic clock, as libinput's
event time is: momentum divides distance by the time between events, never by
when a command arrives. It is reduced to upstream's `u32`: a fraction is
dropped and a value past 2^32 wraps, which the tracker's subtraction expects.
`screen_delta` is the camera's displacement in screen points, with the same
sign as before. It is multiplied by the speed upstream applies to the source and
divided by the current zoom:

| `source` | Speed | Upstream |
| --- | --- | --- |
| `finger`, `wheel`, `continuous` | `navigation.trackpad_speed` | `on_pointer_axis`, the `PanViewport` arm, whatever the axis source |
| `drag` | `navigation.mouse_speed` | `PanGrab::motion` |
| absent | 1 | none: a timed pan that names no source |

That world delta is recorded in the velocity tracker with `time_ms` and added
to the camera. A timed pan whose `time_ms` lies 50 ms (`MOMENTUM_LAUNCH_DELAY`)
or more after the previous one's, with no `pan_end` or stop between them,
empties the tracker first: upstream's timer has launched by then, into a held
pan grab or under resting fingers, and a launch empties it. A drag that rests
with the button held and moves again therefore flings only what moved after the
rest. The output's flight, its zoom anchor and a pending zoom-to-fit
return end, as for every pan. A timed pan other than a `drag` whose
`screen_delta` is zero is dropped whole, as upstream's scroll arm drops it; a
`drag` event that has not moved is still a sample. A `drag` pan also marks the output as held by a pan
grab until its `pan_end`.

`pan` without `time_ms` is the direct move it always was: the camera moves by
exactly `screen_delta / zoom`, no config speed applies, `source` is ignored and
nothing is recorded. It also stops a coast and drops the samples of earlier
timed pans, so nothing launches from it.

`pan_end` is upstream's `launch_momentum_on`: the fingers lifted or the button
was released. The velocity is the tracker's (the displacement of the last 80 ms
of events over their time span, zero with fewer than two samples), the tracker
is emptied, and the output coasts. Sent again, it launches the emptied tracker:
velocity zero, which the next frame turns into rest. That is upstream's own
sequence for a hand that stopped before it let go, where the 50 ms timer has
launched first; see [what the shell owes](#what-the-shell-owes). An output no
timed pan has moved has nothing to launch. `pan_end` also accepts the end
event's own `time_ms`: when it lies 50 ms (`MOMENTUM_LAUNCH_DELAY`) or more
after the last timed pan, the tracker is emptied before the launch, which is
the same result in one call.

### What stops momentum

`momentum.stop()` clears the velocity, the tracker's samples and the coast. It
runs for one output on:

- the prelude of every `action` that names an output, of an `ipc` `Action`,
  of the action a [`hot_corner`](CONFIG.md#hot-corners) runs, of an action
  a gesture's threshold or hold fires and of the `center-nearest` a
  [`pointer_nearest`](POINTER.md#pointer_nearest) fires past its dead zone,
  whatever the action then does
  (upstream's `execute_action`, which there also
  [ends an open cycle](IPC.md#action)); the
  direct `pan_viewport`, `home_toggle`, `zoom_in`, `zoom_out`, `zoom_reset` and
  `zoom_to_fit` commands stop it the same way, also when they arm nothing
- every command that arms a flight: `navigate_window`, a
  [`pick`](POINTER.md#pick-mode) and an armed
  `cycle_navigate` (upstream's `set_camera_anchor`), the `ipc` `Camera`, `Zoom`
  and `Focus` requests, `go-to-bookmark`, a wheel `zoom_by`, and the flights of
  the windows themselves: an [`activate`](NAVIGATION.md#activate) that brings
  a window into view, a new window's `attach`, and a `window_closed`, a close
  or a dismissal whose follower is flown to ([LIFECYCLE.md](LIFECYCLE.md))
- `cancel_navigation` (upstream's `cancel_animations_on`), which the shell
  sends for a press
- a pinch `zoom_by` that begins a gesture or stands alone, and the
  `gesture_begin` of a bound trackpad swipe or pinch (upstream's gesture begin
  calls `cancel_animations`)
- a swipe pan that ends with no end event, because `set-trackpad` or a config
  reload turned the trackpad off under it: nothing is launched
- `pan` without `time_ms`, and `zoom`

and on every output for `begin_drag`, `begin_resize`, `begin_native_resize` and
the drag a move gesture installs
(upstream's grab install, `cancel_animations_everywhere`). A timed `pan` ends
the coast without clearing the tracker, as upstream's `accumulate` does; only
the 50 ms rule above empties it.
Registering an output again or removing it drops its momentum; `load` starts
with none.

An `action` aimed at no output (`"output": null`) stops nothing, as upstream's
prelude does nothing without an active output. A refused action changes
nothing. A [`hover`](POINTER.md#hover) stops nothing either, whether it moves
the focus or not.

## Frames

`tick_navigation` is upstream's `tick_all_animations`. It first arms the
cursor's edge pan again from the last reported pointer, then runs every
connected output, in output id order, through upstream's per-output order:

1. scroll momentum: `MomentumState::tick(dt)` with the frame's elapsed time,
   capped at 33 ms as before, and the camera moved by what it yields
2. edge pan
3. the flight's zoom tick
4. the flight's camera tick

`changed_outputs` lists the outputs whose camera or zoom changed.
`needs_frames` is true while any output has a flight, coasts, or has an edge
pan armed (upstream's redraw loop asks the same of `edge_pan_velocity`), even
while a latency holds that pan back. `needs_pointer` repeats the snapshot's
`navigation.cursor_pan.needs_pointer`.

The clock this command brings is also the one on which a close mark and a
pending relaunch [lapse](LIFECYCLE.md#differences-from-upstream): they are
swept after the frame, as after every command, so a host that ticks only while
`needs_frames` is true must still tick at its idle cadence. A coasting camera
changes what [`state_event`](IPC.md) reports on every frame; a host that
streams it asks at most once a frame.

The first `tick_navigation` of a run establishes the clock with zero elapsed
time, and a frame after an idle stretch is capped at 33 ms, so a coast's first
frame can span up to that much: see [NAVIGATION.md](NAVIGATION.md).

A momentum or edge-pan step that would take the viewport outside the ±1e12
world is not applied and ends that motion, instead of failing the frame and
every frame after it.

## Edge pan while a window is dragged

`gesture_to` may carry `pointer`, the pointer's global screen point, and a
[move gesture](GESTURES.md#dispatch) supplies its virtual pointer the same way
with every update, as upstream's swipe warps the cursor its move grab follows.
During a window drag (`begin_drag`) it is upstream's
`MoveGrab::update_edge_pan`: the
point is made local to the drag's output by subtracting `screen_bounds.origin`,
and inside `navigation.edge_pan.zone` of an edge the output's edge pan is armed
with upstream's ramp. At depth `t` into the zone (0 at its boundary, 1 at the
edge) the speed is `speed_min + (speed_max - speed_min) · t²` screen points
per frame, each edge in reach contributes that speed times its own depth, and a
corner is cut back to the same length. With the defaults (zone 100, 4 to 10)
a pointer 50 from one edge arms 2.75, and one on the edge 10.

Every frame then moves the camera by `velocity / zoom` world points. The
velocity is per frame and not per second, as upstream's is: the shell's frame
rate sets the speed, and 60 Hz is upstream's at 60 Hz. Where upstream warps the
grabbed pointer by the same world delta and its move grab places the window
under it again, the drag adds that delta to the world distance it has been
carried and places its window, or its cluster, again: the window stays under
the held pointer while the canvas pans beneath, and snapping keeps running
against whatever comes into reach. `needs_frames` stays true while the pan is
armed, also while the pointer rests.

The pan is disarmed when the pointer leaves the zone, when the gesture ends
(`end_gesture`, the end of the move gesture that installed the drag, a
source, window or output going away, or a window the drag holds
[closing by itself](LIFECYCLE.md#a-window-closes) or giving way to a stand-in),
and by
`toggle-cursor-pan` turning cursor pan off, which the next `gesture_to` arms
again. A resize gesture never arms one. `gesture_to` without `pointer` arms
nothing and places the window exactly as before.

### Edges that border another output

Upstream's `effective_edge_pan_velocity` holds back the part of an edge pan
that pushes at an edge shared with another output, for
`navigation.edge_pan.latency_ms` (120 by default, 0 for none), so a pointer on
its way to that output crosses instead of dragging the canvas along. Outputs
share an edge where their `screen_bounds` touch along a stretch of positive
length; the stretch is half-open, and outputs meeting only at a corner share
nothing. An outer edge is immediate, at a mixed corner too: there the outer
component pans at once and the other joins after the latency. The wait is
measured on the frame clock from the first frame that sees the pointer at that
set of shared edges, survives moving along them, and starts over once the
pointer leaves the zone. The same rule holds for cursor edge pan.

## Cursor edge pan

The runtime flag is upstream's `cursor_edge_pan`. The first `load_config` of a
run sets it from `navigation.edge_pan.cursor_pan`; after that only the
`toggle-cursor-pan` action changes it. A reload leaves it alone in either
direction, as upstream reads the key once at startup, and `load` keeps it. The
action needs no output, flips the flag and reports nothing else: upstream's arm
has nothing to report either, so the reply is the plain
`{"navigation":null,"effects":[],"dirty":false}` and the flag is the snapshot's
`navigation.cursor_pan.enabled`. Turning it off disarms every edge pan at once.
Either direction forgets the last reported pointer.

`pointer` reports where the pointer is: `output` is the output it is on, or
null for none, and `screen` its global point. While the flag is on, the report
and every frame after it run upstream's `refresh_cursor_edge_pan`: every other
output is disarmed, and the pointer's output is armed with
`cursor_edge_pan_velocity`: `speed_max` screen points per frame, the same
however deep the pointer sits, while it is inside the output's usable area
(the navigation context's `usable_rect_local`) and within
`navigation.edge_pan.cursor_zone` of one of that area's edges. A corner pans
diagonally at the same speed. Outside the usable area, in a reserved strip such
as the menu bar, nothing pans; `speed_min` is not used. A report with no output
disarms. While the flag is off a report is ignored and answers
`needs_pointer: false`.

A grab owns the request, as upstream's does. While a drag or resize gesture is
installed, or a `drag` pan has not had its `pan_end`, reports and frames leave
the request as it stood: a window drag arms its own from its own pointer, and a
resize or a drag pan keeps whatever was armed when it began. A window drag that
begins on an armed cursor pan takes it over after one frame, as upstream's
warped pointer re-drives its move grab: that frame carries the window, and the
request becomes the drag's ramp at the same spot. Upstream stands down under
any pointer grab, the click grab of a plain held button included. The
controller knows only the grabs above, so a press it is never told of, such as
one forwarded to a native window, is the shell's to hold back: see
[what the shell owes](#what-the-shell-owes).

`navigation.cursor_pan.needs_pointer` in the snapshot, and `needs_pointer` in
the `pointer` and `tick_navigation` replies, say whether the shell has to keep
reporting: true exactly while the flag is on.

`pointer` is read for cursor edge pan and nothing else. What a moving pointer
focuses and whose its motion is are [`hover`](POINTER.md#hover)'s, a command of
its own, and the two do not depend on each other: an armed cursor edge pan
holds no pointer from a hover, where a drag pan that has not had its `pan_end`
and a scroll pan yet to launch do
([POINTER.md](POINTER.md#what-holds-the-pointer)).

## Pointer zoom

`zoom_by` replaces the zoom factors the shell used to compute. Both sources
reject during a drag or resize gesture with `navigation during active gesture`,
as every flight does.

**Wheel** is upstream's `on_pointer_axis`, the `Zoom` arm. `delta` is
upstream's vertical axis amount `v`: positive scrolls down and zooms out, and
one wheel notch is 15. The factor is `zoom.step ^ (-delta / 30 ·
zoom.mouse_speed)`, applied to the zoom the output is already heading for (a
pending flight's zoom target, else the current zoom) and held between the
dynamic minimum and 1. When that differs from where it was heading, the output
gets a flight to that zoom anchored on the world point under `anchor`: the
camera target is dropped, a zoom-to-fit return is disarmed and momentum stops.
Later notches compound on the target before any frame runs. Nothing snaps to 1.
`navigation` is the armed `{output,generation,target_camera,target_zoom,animating}`,
or null when the delta is zero or the limit swallows it.

**Pinch** is upstream's pinch gesture, one event at a time. `delta` is the
change in the gesture's scale, the way AppKit reports a magnification, so the
scale upstream reads is one plus the deltas since the gesture began.
`phase: begin` is upstream's `on_gesture_pinch_begin`: the flight and momentum
stop, and the gesture remembers the zoom it started at and the dynamic minimum
of that moment. Each event then sets
`initial_zoom · (1 + (scale - 1) · zoom.trackpad_speed)`, held between that
minimum and 1, at once and around the world point under `anchor`; a change
disarms a zoom-to-fit return. The zoom follows the scale, not the clamp: a
pinch past a limit comes back as soon as the scale does. `phase: end` applies
its own delta and then upstream's end snap: a zoom within 0.05 of 1 becomes 1.
`navigation` is always null.

An event with no `phase` outside a begun gesture is a whole gesture of its own:
it stops the flight and momentum, scales the zoom it finds by
`1 + delta · zoom.trackpad_speed` within the dynamic minimum of that moment, and
holds no state. A lone `end` does the same and then snaps. One pinch is held at
a time, on the output of its `begin`; removing or re-registering that output
ends it.

A [gesture](GESTURES.md#dispatch)'s `pinch_zoom` is the same pinch, begin,
update and end, with three things of its own. `gesture_update` carries
upstream's `scale` itself, so nothing is summed. The anchor is the pointer of
its `gesture_begin` for the whole gesture. And its state is the gesture's, not
the one a `zoom_by` holds: it shows as the snapshot's `trackpad.gesture`, and a
`zoom_by` pinch sent meanwhile is a gesture apart. It is not refused during a
drag or resize gesture.

The dynamic minimum is the one `zoom-out` uses: half the zoom that fits every
window into the usable area with `zoom.fit_padding`, floored at 0.001. A pose
already below it, which `zoom` or a window that moved can leave behind, is
pulled up to it by the next `zoom_by`, as upstream's clamp does.

## Snapshot

`navigation` gains four runtime keys, none of them saved:

- `momentum`: per output that has had a timed pan,
  `{coasting, velocity:{x,y}, panning}`; the velocity is world points per second
- `edge_pans`: per armed output, `{velocity:{x,y}, screen:{x,y}}` in screen
  points per frame and output-local points
- `cursor_pan`: `{enabled, needs_pointer}`
- `pinch`: null, or `{output, initial_zoom, min_zoom, scale}` with `scale` the
  sum of the deltas since `begin`, for the pinch a `zoom_by` holds

## What the shell owes

The controller has no clock but `tick_navigation`'s and sees no device. The
shell must:

- send `time_ms` and `source` with every pan that should coast, from the event
  itself, and ignore the momentum-phase scroll events macOS adds after a lift,
  since momentum is computed here from the fingers' own deltas
- send `pan_end` when a scroll phase ends and when a drag pan's button is
  released
- stand in for upstream's `MOMENTUM_LAUNCH_DELAY` timer: `pan_end` 50 ms after
  the last pan of a device that reports no end, and a second `pan_end` (or the
  end event's `time_ms`) when the end comes 50 ms or more after the last pan,
  so a hand that had stopped flings nothing
- send no `pan_end` for a scroll while a drag pan is held on the same output:
  every `pan_end` is taken for the release, so it would start a coast under
  the held button and end the hold on cursor edge pan
- send no `pan_end` for a scroll whose fingers a trackpad gesture has taken,
  neither at the 50 ms delay nor at the lift: every `pan_end` launches the
  output's one momentum and empties its tracker, so it would spend a swipe
  pan's samples under the fingers, and of that `pan_end` and the swipe's own
  end the second launches nothing and the swipe does not coast
- send `cancel_navigation` for a press, and not between the pans of one
  gesture: it drops their samples
- pass `pointer` with `gesture_to` during a window drag, and report `pointer`
  before each frame while `needs_pointer` says so, but not while a button is
  held: a report made then arms cursor edge pan under a press the controller
  holds no gesture for
- keep ticking while `needs_frames` is true, and start ticking when a reply
  says so, a [gesture](GESTURES.md#reply)'s reply included
- send none of the above for a trackpad gesture: `gesture_begin`,
  `gesture_update` and `gesture_end` carry their own event times, and the
  controller makes the pans, the `pan_end`, the pinch and the drag's pointer of
  them itself

The Infinify shell does it this way. Every scroll pan arms one 50 ms delay
(`native/desktop/pan-launch.m`) that each later pan pushes out, as upstream
arms its timer in every `drift_pan_on`. A trackpad's lift sends `pan_end` and
cancels the delay. A lift, or a drag pan's release, whose event time is 50 ms
or more after the last pan's sends `pan_end` a second time. The shell never
sends `time_ms` with `pan_end`: the two forms give the same result, and the
contract carries both until one is chosen. A scroll that pans an output whose
drag pan is held arms no delay and sends no `pan_end` at its lift; its event
time counts as the drag's last pan, and the release launches. A scroll with
precise deltas is reported as `finger` and any other as `wheel`; `continuous`
is never sent. A window drag sends `pointer` with every `gesture_to`, the frame
timer starts when a reply's `needs_frames` says so, and while the snapshot's
`needs_pointer` is true the pointer is reported before each frame and at the
idle poll, except while a canvas panel holds a button gesture of any kind: a
drag pan, a window drag, a press forwarded to a native window, a pick-mode or
`center-nearest` press, or a native resize. That report and the
[`hover`](POINTER.md#hover) of a moving pointer use one reading of the
pointer: while the frame timer runs, a frame reads it once and sends the
waiting hover, then the report, then the tick. A frame of that timer that
serves an animated background alone ([RENDER.md](RENDER.md)), or a window's
open or close animation ([EFFECTS.md](EFFECTS.md)), sends the
hover and the report the same way and leaves the tick to the idle poll.
Wheel input during a window drag is dropped instead of being sent as a
`zoom_by` that would be refused. No pinch is sent as `zoom_by`: AppKit's
magnify events and the recogniser's pinches go through the gesture commands,
where the `[gestures]` tables decide what a pinch does, so one magnify event
zooms once. No gesture begins while a canvas panel holds a button gesture, and
a press ends the one in progress before it cancels navigation. The 50 ms delay
is armed for scroll pans only: a swipe's own end is its launch. When the
recogniser begins a swipe or a pinch of three or more fingers, the point from
which it also drops the scroll events of those fingers, the shell cancels a
delay still armed and forgets the time of the last scroll pan, so that
scroll's lift sends no `pan_end`; macOS's inertia after it is still dropped. A
two-finger pinch and a hold drop no scroll events and leave a scroll's launch
alone.

## Differences from upstream

- The launch delay is the shell's to time. Upstream's timer starts the coast
  under fingers still resting; here that launch happens only when the shell
  sends the `pan_end` its own 50 ms timer stands for. Only what the timer does
  to the samples needs no shell: the next timed pan empties the tracker when it
  comes 50 ms or more after the last. The Infinify shell sends none for a
  swipe gesture, so the camera stands still under three resting fingers where
  upstream's glides until they move or lift.
- Upstream keeps one pending launch for the whole compositor; here each output
  has its own momentum and is launched by its own `pan_end`.
- Upstream reads a finger scroll event with zero amounts as the lift and
  launches there. Here that event is dropped and the lift is `pan_end`.
- Upstream's momentum tick skips an output held by a pan grab, so a launch
  into the held grab moves nothing and the release launches again. That guard
  has no counterpart: every `pan_end` is taken for the release, and one sent
  while a `drag` pan is held coasts under the button and ends the hold. The
  shell sends none then. A scroll whose fingers lift during a held drag
  therefore keeps its samples until the release, where upstream's lift has
  already spent them: a release within 50 ms of that scroll's last pan flings
  them too, and upstream's flings only what moved after the lift. When the
  button comes up first and the fingers lift within 50 ms of their last pan,
  the lift sends nothing and the coast the release began runs on, where
  upstream's lift launches the emptied tracker and ends it.
- `cancel_navigation` also forgets a `drag` pan whose release never arrived, so
  a lost `pan_end` cannot hold cursor edge pan back for good.
- Every command that arms a flight stops momentum. Upstream stops it in
  `set_camera_anchor`, in the action prelude and in the wheel zoom; its bare
  `set_camera_target` does not. The `ipc` `Camera` and `Zoom` requests therefore
  stop momentum by this contract's rule; upstream's IPC handlers were not read.
- The pointer is a global screen point and is never warped. Upstream keeps the
  pointer on the canvas and shifts it with the camera; nothing here depends on
  which output is active.
- A drag stays on the output it began on. Upstream moves the grab to the output
  the pointer crosses onto and holds back that output's entry edge; here a
  pointer outside the drag's output arms nothing.
- Only edge pan carries a dragged window. A pan, a coast or a `zoom` on the
  drag's output during the drag moves the camera and leaves the window in the
  world, as before; upstream's grab follows every camera move.
- `zoom_by` is refused during a drag or resize gesture. Upstream zooms under a
  grab, and so does a gesture's pinch here.
- Cursor edge pan measures the usable area only. Upstream also stands down
  while the pointer is over a bar or dock surface that reserves no area, on a
  fullscreen output and under a session lock; none of those exist here. The
  experimental native resize transaction does not hold the request, and
  neither does a held button the controller has no gesture for: holding the
  reports back for those is left to the shell.
- A pinch event without a begun gesture is scaled from the zoom it finds, so a
  shell that sends no `phase` gets a multiplicative pinch with no end snap.
- A swipe gesture's update that moves nothing is dropped like a scroll event
  that scrolls nothing, where upstream's swipe records every delta.
- Upstream's wheel-notch action bindings, touch-screen gestures (`[touch]`) and
  their edge pan, the fullscreen locks on every camera write, and
  pointer-constraint handling are absent.

## Evidence and limits

`tests/motion_flow.rs` drives these commands through the exported C ABI on an
output whose global origin is not (0,0). `tests/gesture_flow.rs` drives the
gesture commands into the same code: a flicked swipe's launch and coast are
compared bit for bit with a second controller given the same deltas as timed
finger pans and a `pan_end`, a move gesture's edge pan is checked against
upstream's ramp frame by frame, and its pinch against the formula, the dynamic
minimum and the end snap. See [GESTURES.md](GESTURES.md#evidence-and-limits).

- Momentum is a differential test against `driftwm_core::canvas::MomentumState`:
  the test feeds upstream's type the same world deltas, event times and frame
  durations and requires the camera to be bit-for-bit what it yields, on every
  pan and every frame, for each source at its own config speed, at a zoom other
  than 1, across irregular, capped and repeated frame times, across the `u32`
  wrap of the event clock, for four drift values, and through a reload that
  changes the drift mid-coast. A drag that rests 60, 50 and 49 ms with no
  `pan_end` and then moves again is compared the same way, the oracle
  launched where upstream's timer would have. It also checks one command on
  each stop path (the action prelude, `navigate_window`, the `ipc` `Camera`
  and `Zoom` requests, a timed and an untimed `pan`, `zoom`,
  `cancel_navigation`, `begin_drag`, `begin_resize`, a wheel and a stand-alone
  pinch `zoom_by`, `remove_output`); an armed `cycle_navigate`, the `ipc`
  `Focus` request, `go-to-bookmark`, `begin_native_resize`, a pinch `begin`,
  registering an output again and `load` reach the same code and are not
  asserted. It checks the commands that must not stop it, a coast interrupted
  by a new flick, two outputs coasting independently, and that an untimed pan
  is exactly `screen_delta / zoom` and never coasts.
- Edge pan, the latency rule, cursor edge pan and both zooms are checked against
  values derived by hand from upstream's formulas, with the same arithmetic in
  the same order where exactness is claimed: the ramp at several depths and
  corners, the per-frame step at zoom 0.5, the dragged window's world rectangle
  after every frame and its drawn position staying put, a carried cluster, the
  half-open shared stretch and the mixed corner, the cursor zone against an
  inset usable area, the toggle, the launch-only flag, the wheel target and its
  fixed anchor on every frame, and the pinch's scale, clamps and end snap.
  Upstream's own functions are not executed for these, so parity is by reading.

This is controller evidence only. It does not show that a scroll, drag, pinch
or pointer position reaches the shell, that macOS momentum events are ignored,
that frames are scheduled or drawn, or how any of it feels under a hand. A
scripted session on 2026-10-09 against the app built from these sources, in
`--windowed` mode, reached what a socket can: `toggle-cursor-pan` accepted
twice, a config file with these settings loaded and reloaded with nothing on
stderr, and flights landing exactly through the reordered frame. No timed
`pan`, `pan_end`, `zoom_by` or `gesture_to` with a pointer was produced by real
input, and no `pointer` report led to a pan, so momentum, edge pan and cursor
edge pan have not been exercised in the running app. The same holds for the
session of 2026-10-10 on the tree that also has window navigation, hot
corners, the event stream and managed windows, where the frame is the
navigation coordinator's tick: `toggle-cursor-pan` twice, a file with these
settings loaded with nothing on stderr about it, and `center-nearest`,
`center-window`, `pan-viewport`, `zoom-to-fit` and `home-toggle` flights
landing exactly, with a `subscribe` client receiving 46 State lines, no two
alike in a row, over the 1.6 seconds two of those flights took. Nor have the shell's
rules that need a held button or a moving window: holding back pointer
reports, leaving a scroll's launch to a held drag pan's release, handing a
scroll over to a window, and dropping zoom input during a window drag are
compiled and read only. The shell's side and that run are described
in the [shell notes](../../native/desktop/README.md#camera-motion).

That run was of this change by itself. The app built after
[trackpad gestures](GESTURES.md) were put on the same code was driven the same
way once more, and
[GESTURES.md](GESTURES.md#put-together-with-camera-motion-2026-10-09) has that
run. It reached the same things and no more: no scroll, drag, swipe or pinch
was produced by real input.
