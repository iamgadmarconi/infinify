# Trackpad gestures

DriftWM is trackpad-first: three fingers pan, four fingers jump to the nearest
window, pinches zoom or toggle the overview, a hold fires an action, a
three-finger tap followed by a swipe moves a window, and all of it is bound in
the `[gestures]` tables of the [config file](CONFIG.md). This document covers
the controller's side: three commands that carry a gesture, and upstream's
dispatch of them. The recogniser that produces them from raw touches is the
shell's, see the [shell notes](../../native/desktop/README.md).

## The event contract

Upstream receives ready-made gestures from libinput: a swipe, a pinch or a hold,
each with a finger count, as a begin, any number of updates and an end. macOS
has no such stream, so the shell synthesizes one and sends it in three commands.
They are additions to ABI v1; no existing command changed.

```json
{"op":"gesture_begin","kind":"swipe","fingers":3,
 "modifiers":{"control":false,"option":false,"shift":false,"command":false},
 "context":"canvas","output":1,"pointer":{"x":812.0,"y":640.5},
 "doubletap":false,"time_ms":51234}
{"op":"gesture_update","dx":4.5,"dy":-1.25,"time_ms":51242}
{"op":"gesture_update","scale":0.93,"rotation":0.0,"dx":0.0,"dy":0.0,"time_ms":51250,"held":false}
{"op":"gesture_end","cancelled":false,"time_ms":51300,"held":false}
```

`gesture_begin`:

| Field | Meaning |
| --- | --- |
| `kind` | `swipe`, `pinch` or `hold`: the libinput gesture |
| `fingers` | the finger count, fixed for the gesture. Upstream's grammar binds 2 to 5 |
| `modifiers` | the physical modifiers held when the gesture began, real booleans, as for `mouse_binding`. A missing key is `false` |
| `context` | `window` or `canvas`: what is under the pointer, as for `mouse_binding` |
| `output` | the output under the pointer. The gesture is pinned to it until it ends |
| `pointer` | the pointer, a global screen point, top-left origin, Y down. The zoom anchor, and where a move looks for its window |
| `doubletap` | optional, default `false`, swipes only: a three-finger tap ended at most 300 ms before this swipe began. See [Doubletap-swipe](#doubletap-swipe) |
| `time_ms` | the event time in milliseconds on any monotonic clock, as libinput stamps its events. A fraction is accepted and dropped; the value wraps at 2³² as libinput's does |

`gesture_update` carries what libinput reports for the kind. Every field but
`time_ms` is optional.

| Field | Meaning |
| --- | --- |
| `dx`, `dy` | a swipe's motion since the previous event, in screen points: X right, Y down, the physical direction the fingers moved. One unit is what moves upstream's cursor one logical pixel, so a move gesture carries its window exactly this far on screen. Default 0 |
| `scale` | a pinch's scale relative to the start of the gesture, as libinput's: 1 is no pinch, below 1 the fingers have closed. Not a per-event factor. Default 1, must be positive |
| `rotation` | a pinch's rotation. Accepted and unused: upstream only forwards it to a client. Default 0 |
| `held` | a real boolean, default `false`: a real modifier is physically down as this event arrives. It is [`action`'s `held`](IPC.md#action), read only when the event fires an action, and it matters to `cycle-windows` alone: see [Dispatch](#dispatch) |
| `time_ms` | as above |

`gesture_end` has `cancelled` (optional, default `false`), `held` as above, for
the action a hold fires, and `time_ms`.
libinput cancels a gesture when the finger count changes under it; the shell
does the same, and also when the system takes the touches away.

Sequencing:

- One gesture is in progress per controller. A `gesture_begin` that arrives
  while one is in progress first ends the stale one as cancelled, so a lost
  `gesture_end` cannot lock every later gesture out.
- `gesture_update` and `gesture_end` with no gesture in progress are accepted
  and do nothing: their reply's `gesture` is `null`. That is what follows a
  begin the trackpad setting suppressed, or an output that went away.
- A gesture nothing is bound to is not an error. Its state is `unbound` and its
  events do nothing.
- A malformed command (unknown output, a non-finite number, a `scale` of 0, an
  unknown field) is a controller error and changes nothing, as everywhere.

These are not `begin_drag`, `gesture_to` and `end_gesture`, the pointer's drag
and resize commands of the [controller ABI](README.md). A move gesture drives
that same drag internally.

### Reply

All three reply alike:

```json
{"gesture":{"state":"swipe_threshold","output":1,"window":null,
            "bindings":[{"combo":"4-finger-swipe","action":"center-nearest","implemented":true}]},
 "fired":null,"note":null,
 "navigation":null,"effects":[],"dirty":false,"needs_frames":false,"trackpad":true}
```

- `gesture` is the gesture in progress, or the one that just ended, or `null`.
  `state` names what the gesture resolved to, see below. `window` is the window
  a move or a resize grabbed. `bindings`, in the begin reply only, lists the
  bindings the gesture resolved: the upstream combo text, the action as a config
  file spells it, and whether that action does anything here. The end reply
  adds `cancelled`.
- `fired` is `null`, or `{"action","error"}` when this event fired a threshold
  action: `action` is the exact action string dispatched, such as
  `center-nearest down-left`, and `error` is `null` or the action command's own
  refusal, such as `action not implemented on macOS yet: toggle-fullscreen`. A
  refused action is reported here and is not a controller error, because an
  error would undo the gesture's own state and the action would fire again on
  the next update.
- `note` is `null`, or why a claimed gesture does nothing. A resize has one.
- `navigation`, `effects` and `dirty` are the [action command](IPC.md)'s: the
  flight a fired action armed, requests to the shell (a fired `exec`, and the
  `focus_native_window` request of a move or of a fired
  [window navigation action](NAVIGATION.md#window-navigation-actions)), and
  whether the saved scene changed.
  A gesture that moved a camera or a window, or changed focus, reports `dirty`
  once, with the event that ends it; an update that moves the camera does not
  repeat it. A fired action's own `dirty` arrives with the event that fired it.
- `needs_frames` is true while a flight is armed, a camera is coasting or an
  edge pan is armed on any output, as in every [camera motion](MOTION.md#frames)
  reply: the shell keeps `tick_navigation` running until it reads false.
- `trackpad` is whether gesture dispatch is on, see [set-trackpad](#set-trackpad).

The snapshot gains `trackpad`: `{"enabled","gesture","coasting"}`, the gesture
in progress and the outputs whose cameras are coasting. `coasting` is a view of
the snapshot's `navigation.momentum`, the one momentum there is: a coast a
scroll or a drag pan launched is listed too. None of it is saved.

## Why this path and not the touch recogniser

Upstream has two gesture dispatchers. Trackpad gestures arrive from libinput
already recognised and are dispatched in `src/input/gestures/` against the
`[gestures]` tables: modifiers take part, the finger floor is two, and the
swipe threshold is in pointer units. Touchscreen gestures arrive as raw touch
points and are recognised by `src/grabs/touch_recognizer.rs` against the
separate `[touch]` tables: no modifiers, one-finger gestures, tap, doubletap and
hold-swipe triggers, and thresholds in millimetres of panel travel.

A Mac trackpad is upstream's trackpad. Its bindings are the `[gestures]` ones,
so the controller adapts the libinput-event dispatch, and the shell stands in
for libinput. `driftwm-core` carries upstream's touch recogniser verbatim; it is
not used here, and `[touch]` stays read and unapplied.

## Dispatch

The binding is looked up once, at begin, and holds for the gesture, as
upstream's `GestureState` does. The lookup is upstream's `gesture_lookup`: the
pointer's own context table (`on-window` or `on-canvas`), then `anywhere`. The
physical chord is mapped back to upstream modifiers exactly as for a
[pointer binding](CONFIG.md#macos-modifiers): it may stand for more than one
upstream modifier set (Control+Option is both `mod` and `ctrl+alt`), and every
such set is tried in combo order in the pointer's own table before any is tried
in `anywhere`. Modifiers must match exactly: a chord no binding names is
unbound, never the unmodified binding.

| `state` | Chosen when | What it does |
| --- | --- | --- |
| `swipe_pan` | `N-finger-swipe` is `pan-viewport`; or `zoom` (a swipe has no scale); or a move or resize with no window under the pointer | each update is the [timed `pan`](MOTION.md#timed-pans-and-momentum) of a finger scroll: the camera moves by `-(dx, dy) · navigation.trackpad_speed / zoom` canvas points, so the canvas follows the fingers, and the output's momentum hears the delta at the event's `time_ms`. The end is that pan's `pan_end`, see [Momentum](#momentum) |
| `swipe_move` | `N-finger-swipe` or `N-finger-doubletap-swipe` is `move-window` or `move-snapped-windows`, and a window is under the pointer | focuses and raises the window, then installs the drag a bound button press installs, with the cluster for `move-snapped-windows`. Each update moves a virtual pointer by the raw `(dx, dy)`, held inside the gesture's output, and the window follows it with the usual snapping, as under `gesture_to` with that `pointer`: inside `navigation.edge_pan.zone` of an edge the drag's [edge pan](MOTION.md#edge-pan-while-a-window-is-dragged) is armed and the canvas pans under the window frame by frame. On end the drag is released and its edge pan with it. Over a [screen-pinned window](RULES.md#screen-pinned-windows) the drag is its [screen-space drag](RULES.md#dragging-a-pinned-window), as upstream's `GestureTarget::Pinned` arm installs the pinned move grab: the window is raised and focused and follows the virtual pointer point for point whatever the zoom, on the gesture's output, with no snapping, no cluster and no edge pan |
| `swipe_resize` | the same triggers bound to `resize-window` or `resize-window-snapped`, over a window | nothing: native layout resize is gated. The begin reply's `note` says so |
| `swipe_threshold` | `N-finger-swipe` is a threshold action, or only named directions are bound | accumulates the physical vector; when its length reaches `gestures.swipe_threshold` (12) it fires once. `N-finger-swipe-up/down/left/right` win in the physical direction the fingers moved, the larger axis deciding; otherwise the `N-finger-swipe` action fires. A bare `center-nearest` takes the opposite of the vector, in eight directions: fingers left look right |
| `pinch_zoom` | `N-finger-pinch` is bound (it can only be `zoom`) | the [pinch](MOTION.md#pointer-zoom) a `zoom_by` makes, given the scale itself: zoom = start zoom · `(1 + (scale − 1) · zoom.trackpad_speed)`, held between the dynamic minimum of the begin and 1.0, around the pointer. On end, cancelled or not, a zoom within 0.05 of 1.0 snaps to it |
| `pinch_threshold` | no continuous pinch, and `N-finger-pinch-in` or `-out` is bound | fires the in action once when `scale` drops below `gestures.pinch_in_threshold` (0.85) and the out action once when it rises above `gestures.pinch_out_threshold` (1.15). One gesture can fire both |
| `hold` | `N-finger-hold` is bound | fires its action when the hold ends, unless it was cancelled |
| `unbound` | nothing matched | nothing |

A bound swipe or pinch cancels the output's flight and stops its momentum when
it begins (upstream's `cancel_animations`), and a move, installing a grab, does
so on every output. A hold and an unbound gesture do not, with one exception
that is upstream's too:
a swipe that carries `doubletap` cancels them as soon as an
`N-finger-doubletap-swipe` binding is found in its context, whatever the swipe
then resolves to. With no window under the pointer to grab and no
`N-finger-swipe` bound, that is an `unbound` gesture that stopped a flight.

Neither the lookup nor a move reads [pick mode](POINTER.md#pick-mode):
upstream's gesture handlers never ask for it, so below `zoom.interact_min` a
gesture resolves and acts exactly as above, and a move over a pick target
moves it. From `gesture_begin` to `gesture_end`, whatever the gesture resolved
to, it [holds the pointer](POINTER.md#what-holds-the-pointer): a
[`hover`](POINTER.md#hover) moves no focus and answers `forward: false`.

Threshold and hold actions run through the [action dispatch](IPC.md#action),
so each does exactly what its key binding, `msg action` or hot corner does. The
gesture supplies what that command takes:

- the active `output` is the gesture's own, pinned at begin;
- `pointer` is the pointer where the gesture began, which `focus-center` reads;
- `held` is the `held` of the event that fires the action. With it true a fired
  `cycle-windows` leaves its cycle open until the shell sends
  `end_focus_cycle`, and the next swipe steps it further; with it false the
  step is committed at once, as a key binding fired with no modifier down is.

The dispatch runs upstream's `execute_action` prelude once, as for every other
source: an action that is not `cycle-windows` first ends an open cycle,
committing a confirmed selection, and every action stops the output's
[scroll momentum](MOTION.md#what-stops-momentum). So a four-finger swipe is
upstream's `center-nearest` in the eight directions: the nearest window in the
90° cone is raised, focused and flown to at the current zoom, a
`navigation.anchors` point is flown to with focus cleared, and an empty cone
does nothing ([NAVIGATION.md](NAVIGATION.md#window-navigation-actions)). An
action that is not implemented yet answers
`action not implemented on macOS yet: <name>` in `fired.error`. Whatever an
action needs that the gesture did not supply (a focused window for
`close-window`) is the action's own rule.

### Doubletap-swipe

libinput has no doubletap gesture. Upstream configures tap-to-click so that a
three-finger tap is a middle click, holds that click back for 300 ms
(`DOUBLE_TAP_WINDOW_MS`), and treats a swipe that begins inside the window as
`N-finger-doubletap-swipe`, with N the swipe's own finger count. `doubletap` on
`gesture_begin` is that pending click. With it set:

- if `N-finger-doubletap-swipe` is bound to a move and a window is under the
  pointer, the gesture is `swipe_move`; bound to a resize over a window, it is
  the inert `swipe_resize`;
- "a window under the pointer" is upstream's `gesture_target_under`, in the
  order a press resolves: the windows pinned to the output, then the canvas
  windows, then the widgets. A [widget](RULES.md#widgets) is grab-proof and
  counts as nothing there, so the gesture is an ordinary swipe and no window
  beneath is reached, a pinned widget included; a pinned window makes a move
  `swipe_move`, of the pinned window itself, and a resize `swipe_resize`.
  The same holds for a plain `N-finger-swipe` bound to a move or a resize;
- otherwise (no such binding, a binding in the other context, nothing under the
  pointer, or the pointer already dragging something) it is an ordinary swipe.

Upstream delivers the held-back middle click to the client when the swipe does
not consume it. Here there is no click to deliver: macOS does not turn a
three-finger tap into one.

## The default table on a Mac

Upstream's default `[gestures]`, with the default super chord (`mod` is
Control+Option) and `mod_key = "super"`. "Runs" means the action executes in
this build; the others are dispatched and refused by name until their actions
exist. The `implemented` flag of each binding in the begin reply is the live
answer, and `gesture_flow`'s `the_default_table_on_a_mac` reads it for every
row: upstream binds 22 gestures, of which 14 run here, 6 are refused by name
and the 2 resizes are claimed and inert. Four of the six, the two `fit-window`
and the two `fit-window-snapped` pinches, run once the shell has sent
`native_resize_capability`, and so do the two `toggle-fullscreen` pinches
([FULLSCREEN.md](FULLSCREEN.md)).

| Input | Upstream binding | Context | Action | Here |
| --- | --- | --- | --- | --- |
| 3-finger swipe | `3-finger-swipe` | anywhere | `pan-viewport` | runs, and coasts |
| 4-finger swipe | `4-finger-swipe` | anywhere | `center-nearest` | runs: fires `center-nearest <dir>`, fingers left looking right |
| ⌃⌥ 3-finger swipe | `mod+3-finger-swipe` | anywhere | `center-nearest` | the same |
| 3-finger tap, then 3-finger swipe | `3-finger-doubletap-swipe` | on-window | `move-window` | runs |
| ⌥ 3-finger swipe | `alt+3-finger-swipe` | on-window | `resize-window` | claimed, does nothing: gated |
| ⌥⇧ 3-finger swipe | `alt+shift+3-finger-swipe` | on-window | `resize-window-snapped` | the same |
| 2-finger pinch | `2-finger-pinch` | on-canvas | `zoom` | runs |
| ⌃⌥ 2-finger pinch | `mod+2-finger-pinch` | anywhere | `zoom` | runs |
| 3-finger pinch | `3-finger-pinch` | anywhere | `zoom` | runs |
| 4-finger pinch in | `4-finger-pinch-in` | anywhere | `zoom-to-fit` | runs |
| 4-finger pinch out | `4-finger-pinch-out` | anywhere | `home-toggle` | runs |
| ⌃⌥ 3-finger pinch in | `mod+3-finger-pinch-in` | anywhere | `zoom-to-fit` | runs |
| ⌃⌥ 3-finger pinch out | `mod+3-finger-pinch-out` | anywhere | `home-toggle` | runs |
| ⌃⌥ 4-finger pinch in | `mod+4-finger-pinch-in` | anywhere | `zoom-to-fit-snapped` | runs |
| ⌥ 2-finger pinch in or out | `alt+2-finger-pinch-in`, `-out` | on-window | `fit-window` | runs with the capability, which every normal run sends, else refused: [SIZES.md](SIZES.md#the-gate) |
| ⌥⇧ 2-finger pinch in or out | `alt+shift+2-finger-pinch-in`, `-out` | on-window | `fit-window-snapped` | the same |
| ⌥ 3-finger pinch in or out | `alt+3-finger-pinch-in`, `-out` | on-window | `toggle-fullscreen` | refused without the capability |
| 4-finger hold | `4-finger-hold` | anywhere | `center-window` | runs, on release |
| ⌃⌥ 3-finger hold | `mod+3-finger-hold` | anywhere | `center-window` | the same |

What follows from the table and the lookup order:

- A bare two-finger pinch over a window is unbound, as upstream leaves it to the
  application. Nothing forwards it to the native window under the overlay.
- Two-finger scrolling is not a gesture here or upstream: it stays a
  [pointer binding](CONFIG.md), `trackpad-scroll`.
- Five fingers, three-finger hold and four-finger doubletap-swipe have no
  default binding.
- `"<binding>" = "none"` in the file removes a default, and `[bindings]
  disable_defaults = ["gestures"]` removes them all.
- A malformed entry is upstream's warning, not an error. `load_config` lists
  `config: invalid gesture binding '<key>' = '<action>': <reason>`, or
  `config: invalid gesture binding '<key>': <reason>` when the trigger itself
  does not parse, under `warnings`; that one entry is skipped, a default it
  would have replaced stays bound, and the rest of the file is accepted. Only a
  file the TOML parser refuses, such as a `swipe_threshold` that is not a
  number, is a `config error:` that leaves the previous configuration in force.

## set-trackpad

`set-trackpad on|off|toggle` now runs. Upstream sets libinput's send-events mode
on every trackpad, which silences the device altogether; the controller owns no
device, so what it turns off is gesture dispatch: while off, `gesture_begin`
starts nothing, its reply has `"gesture":null,"trackpad":false`, and the events
of that gesture do nothing. Turning it off, by the action or by a config reload,
also ends a gesture in progress, as a disabled device cancels its own; if that
gesture had moved a camera or a window, the action's or the reload's own reply
is `dirty`, since no `gesture_end` will report it. A swipe pan ended this way
launches nothing: there is no end event to time a launch by, and its samples
are dropped. The
pointer, clicks and two-finger scrolling, which upstream's off also silences,
are macOS's and stay on; the shell's two-finger pinch goes through
`gesture_begin` and is therefore off.

The state follows upstream's `effective_send_events`: a `set-trackpad` of this
run if there has been one, otherwise `[input.trackpad] enable` (default true).
The override lasts until the process exits or until a loaded config changes the
trackpad's resolved mode, as upstream documents for `enable`. It is never saved,
and a scene `load` keeps it. `disable_on_external_mouse` counts as on: no
device is watched. The action's reply does not carry the state; read it from
the snapshot or from any gesture reply.

## Momentum

There is one momentum: each output's `MomentumState`, upstream's own code, which
[camera motion](MOTION.md#timed-pans-and-momentum) keeps. A swipe pan feeds it
as upstream's `SwipePan` feeds `drift_pan_on`, and ends as upstream's swipe end
calls `launch_momentum_on`, cancelled or not: libinput cancels a swipe whenever
one finger lifts ahead of the others. So for the controller a swipe pan is

- per update, `pan` with `screen_delta` `-(dx, dy)`, the update's `time_ms` and
  `source: finger`;
- at its end, `pan_end` with the end's `time_ms`.

Everything that follows is that contract's and is written there once: the
velocity (the displacement of the last 80 ms of events over their time span),
the decay by `navigation.drift`, the frames (`tick_navigation` advances the
coast, lists the output in `changed_outputs` and keeps `needs_frames` true),
and [what stops it](MOTION.md#what-stops-momentum). Three of its rules show in
every swipe:

- Upstream arms a timer with every delta (`MOMENTUM_LAUNCH_DELAY`, 50 ms) that
  launches the coast with the fingers still down and empties the tracker. An
  end that comes 50 ms or more after the last update therefore launches an
  empty tracker: `needs_frames` is true in its reply, and the next frame finds
  no velocity and is at rest, with the camera where the fingers left it. An end
  sooner than that coasts.
- An update that comes 50 ms or more after the previous one starts the tracker
  afresh, so a single delta after a pause is no velocity.
- `drift = 0` is upstream's "momentum disabled", and what its `MomentumState`
  does with it: the launch is made, the first frame that has any duration
  spends the whole velocity, and the frame after that is at rest.

The timer's own launch is not reproduced for a swipe. Upstream's camera glides
from 50 ms after the last delta until the fingers move again or lift; here it
stands still under resting fingers, because the controller has no clock between
events and the shell arms its 50 ms delay for scroll pans only.

The controller launches at a cancelled end as upstream does. The shell follows
the cancelled end of a pan with `cancel_navigation` on its output: the only
cancelled ends its recogniser produces within 50 ms of an update are touches
taken away, by the system or by a button press, and that camera should stop.
The [shell notes](../../native/desktop/README.md#trackpad-gestures) say why.

## Differences from upstream

- Events are synthesized from raw touches by the shell, not reported by
  libinput. Finger count, the settle window, what counts as a swipe, a pinch or
  a hold, the hold delay, and the unit of `dx` and `dy` are the shell
  recogniser's imitation of libinput, documented at the top of
  `native/desktop/trackpad-gestures.m`. The dispatch cannot be more faithful
  than the stream it is given.
- An unbound gesture is forwarded to the focused client upstream. Here it does
  nothing.
- `resize-window` and `resize-window-snapped` are claimed and inert: native
  layout resize is gated. Upstream resizes through its pointer grab.
- A move's virtual pointer is held inside the gesture's output, where upstream's
  cursor also crosses to a neighbouring output and takes the window with it.
  A screen-pinned window is moved in screen space by the same gesture, raised
  and focused, as upstream's is; held inside the gesture's output like any
  move's pointer, it is not carried to another output, which upstream's
  cursor can do. A widget is grab-proof, as upstream's is.
- The gesture handlers' fullscreen legs are [FULLSCREEN.md](FULLSCREEN.md#leaving)'s:
  on a fullscreen output a gesture resolves in the window context, and a
  continuous one ends the fullscreen first. A move gesture therefore takes a
  pinned window of that output only once its fullscreen has ended and the
  pinned windows are drawn again.
- No pointer warp: upstream moves its cursor with a pan, a zoom and a move. The
  macOS pointer stays where it is, so the zoom anchor is the pointer at begin.
- A swipe update that moves nothing is not a sample: the timed finger pan drops
  it, as upstream's scroll arm does, where upstream's swipe hands every delta to
  `drift_pan_on`. The shell's recogniser sends no such update.
- The launch delay's own launch is not run for a swipe, see
  [Momentum](#momentum), and a pan, a coast or a pinch on a dragged window's
  output leaves the window in the world: those are
  [camera motion's differences](MOTION.md#differences-from-upstream) and hold
  for a gesture as for a scroll. A gesture's pinch is not refused during a
  pointer drag or resize, where `zoom_by` is; upstream zooms under a grab too.
- A threshold action that is refused is reported in `fired.error`. Upstream has
  no refused actions.
- Lookup with an ambiguous chord tries every upstream modifier set the chord
  stands for; upstream has one modifier state.
- `set-trackpad` turns gesture dispatch off, not the device.
- A `gesture_begin` during a gesture cancels the stale one. libinput never
  sends that.
- libinput ends every gesture it begins; raw touches can simply stop. The
  recogniser ends a gesture when every finger lifts, cancelled when macOS
  cancels a touch or a frame no longer reports one, and the shell cancels it
  at a button press, a screen change and when the canvas closes. Since
  2026-10-10 two more ends close what was left, checked on every frame and
  every poll: the gesture's output is no longer what a press at the pointer
  would reach (Mission Control, another window or a menu over the canvas:
  touches go to the view under the pointer, so they are no longer the
  panel's), and, for a move gesture only, no touch at all for thirty seconds.
  A move is the one gesture whose lost end is not harmless: it holds a drag,
  under which every flight is refused and the edge pan carries the window on
  every frame ([MOTION.md](MOTION.md#what-the-shell-owes)). The second rule
  cannot be made exact: still fingers send no touches either, and nothing
  reports the fingers on the pad between events. So it is made harmless
  instead. The time is long, thirty seconds without the least movement of a
  finger, and only the controller's gesture is ended (`gesture_end`,
  cancelled): the recogniser keeps its fingers and its swipe, whose later
  updates and end the shell drops for want of an owner, so fingers that were
  only resting end their move and cannot begin another gesture until they
  lift. The first rule resets the recogniser too, since those touches are
  another view's. A move whose touches are truly lost is carried by the edge
  pan for those thirty seconds at most. Neither rule was exercised on a
  trackpad.
- Read from upstream's sources for this port: `src/input/gestures.rs`,
  `src/input/gestures/{swipe,pinch,hold,device_config}.rs`, the config types
  and defaults, `README.md` and `docs/config.md`; what the gestures drive
  (momentum, the pinch, the move grab's edge pan) is
  [camera motion](MOTION.md)'s reading of its own sources. Not read: the
  pending-middle-click code in the pointer handler, the `set-trackpad` arm of
  `execute_action`, and the reload code. So two things are this port's
  choices or its reading of call sites and documentation, not of the code
  itself:
  - `set-trackpad toggle` is "the other of on and off", and the override is
    dropped when a loaded config's resolved trackpad mode differs from the
    previous config's;
  - `doubletap` is supplied by the shell as a boolean. Upstream's rule for
    which clicks arm the 300 ms window is not reproduced beyond "a
    three-finger tap".

## Evidence and limits

`gesture_flow` drives synthetic event streams through the exported C ABI and the
JSON decoder, on an output whose global origin is (300, 200), with upstream's
built-in table and with config files in a throwaway directory. It checks:

- the three-finger pan's camera displacement at zoom 0.5 on canvas and over a
  window, beside a second output that must not move;
- the coast after a flick: the launch and every frame bit for bit those of a
  second controller given the same deltas as timed finger `pan`s and a
  `pan_end`, until `needs_frames` is false; what stops it; `drift = 0`, one
  frame of travel; and that a cancelled swipe still coasts;
- the launch delay on both sides (an end 49 ms after the last update coasts, one
  at 50 ms launches nothing and is at rest a frame later) and the tracker
  starting afresh after such a pause;
- the shell's order for a press during a moving pan: the cancelled end, then
  `cancel_navigation`, then `begin_drag`, and a camera that then stays put;
- the four-finger swipe in the four cardinal and four diagonal directions:
  nothing before the threshold and exactly one `center-nearest <dir>` at it,
  which runs: the flight and the focus request toward the window that cone
  holds, nothing for an empty cone, and in every case the reply and the scene
  it leaves equal to the action command's own on a second controller;
- the three-finger pinch: the canvas point under the pointer fixed at every
  step, the 1.0 ceiling, the snap at the end, the dynamic floor, and a pose
  below that floor pulled up to it;
- the two-finger pinch's contexts, the four-finger pinch in and out firing
  `zoom-to-fit` and `home-toggle` once each with their flights, and the `mod`
  and `alt` variants;
- the hold firing on release and not when cancelled, `center-window` flying to
  and focusing the window nearest the middle of the view;
- a gesture's `pointer` and `held` reaching the action: `focus-center` over a
  window and over empty canvas, a `cycle-windows` step committed at once
  without `held`, held open and stepped forward and back with it, released by
  `end_focus_cycle`, and ended by another action a gesture fires; the same for
  a hold's end;
- the action prelude's momentum stop for the window, output and layout
  actions, by `action`, by an `ipc` `Action` and by a hot corner;
- the default table above, row by row, against the count of upstream's default
  bindings;
- the doubletap-swipe move: focus, one-to-one motion, zoom, the output-edge
  clamp, the fall back to a plain swipe; and at the edge, the pan under the
  held window by upstream's ramp, the window carried with the camera on every
  frame, the pan disarmed by moving back and by the gesture's end;
- cancellation, a lost end, the pointer path or a removed window or output
  ending things under a gesture, and a move gesture leaving alone a drag the
  pointer began after ending the gesture's own;
- a window that [closes by itself](LIFECYCLE.md) under a move, by gesture and
  by button: the drag and its edge pan end with it, another window's close
  ends neither, and the gesture goes on with nothing to move;
- the State event line of a coasting camera: one new line for every frame that
  moves it, none twice and none at rest;
- a config file's bindings, thresholds and speeds, `"none"`, per-direction
  triggers, `disable_defaults`, and a reload;
- `set-trackpad` by action, IPC, gesture and config, and its override rule;
- malformed events.

Expected values are derived by hand from upstream's handlers as read. Those
handlers are compositor code and are not executed as an oracle, so parity with
them is by reading, not by differential test.

This is controller evidence only. It does not show that the shell's recogniser
produces these streams from real touches, that macOS delivers three- and
four-finger touches to the canvas (its own Mission Control, Spaces and Launchpad
gestures must be turned off in System Settings for that), that a frame is
drawn, or that a window moves on screen. No part of this was run against a
trackpad.

### Integration run, 2026-10-09

The two halves were built together for the first time (`scripts/build-app.sh`,
ad-hoc signed, macOS 27.2, Apple Silicon) and nothing had to change to make
them fit. Nothing from this run is saved as evidence. **No physical trackpad
gesture was performed**: an automated session has no fingers, and touch input
cannot be injected. What was run instead:

- **The built app over its socket.** One launch as `--windowed 1100x700` on a
  private scene (three seeded detached placeholders), config and socket, driven
  through `Infinify msg`:
  - a config file with a `[gestures]` override in upstream's grammar
    (`swipe_threshold`, `pinch_in_threshold`, `"3-finger-swipe" = "none"`,
    rebound four- and five-finger swipes, a per-direction trigger and an
    on-canvas hold) loaded with nothing on stderr, and the bookmark the same
    file defines read back over the socket;
  - `action set-trackpad off`, `on`, `toggle` (twice) and `OFF` each answered
    `ok` with exit status 0; `set-trackpad maybe` answered upstream's
    `set-trackpad: expected on, off, or toggle, got 'maybe'` and a bare
    `set-trackpad` answered `set-trackpad requires on, off, or toggle`, each
    with exit status 1. The resulting on/off state is in the snapshot and in
    gesture replies, neither of which the socket reaches, so it was not read
    back there;
  - the file rewritten with four malformed gesture entries: upstream's four
    warnings on stderr (`per-direction swipe triggers only accept threshold
    actions, not 'pan-viewport'`, `finger count must be 2-5, got 7`, `unknown
    gesture type: 'wiggle'`, `unknown gesture action: 'frobnicate'`), each
    printed once by the file watch and once by `reload-config`, and the file
    otherwise accepted: the bookmark it moved read back at its new point;
  - the file rewritten with `swipe_threshold = "far"`: upstream's
    `config error: TOML parse error … invalid type: string "far", expected f64`
    on stderr, and the bookmark that file also moved still at the previous
    file's point;
  - `camera 400 -250`, `zoom 0.5`, `home-toggle` (to `0 -0` at zoom 1 and
    back), `zoom-to-fit` (to `750 -390` at 0.28484848484848485 and back) and
    `pan-viewport right` (200 canvas points at zoom 0.5) each landing on the
    same values as before this milestone, on the frame timer that now also
    serves a coast; `center-nearest up` still refused by name;
  - SIGTERM: exit status 0, socket file removed.
- **The recogniser into the controller, without AppKit.** A throwaway
  command-line program outside the repository linked the real
  `trackpad-gestures.m` and the real controller library, added to each
  `gesture_begin` the fields the shell adds, and played nine scripted touch
  sequences in millimetres. All 95 events the recogniser emitted were accepted
  by the controller. Seen there, under upstream's default table: three fingers
  swiping right 30 mm became `swipe_pan`, moved the camera 378 points (24
  updates of 10.5 units at `trackpad_speed` 1.5) and coasted for 56 frames;
  four fingers swiping up fired `center-nearest down` once, refused by name;
  a three-finger tap and a swipe 206 ms later over a window carried
  `doubletap`, became `swipe_move` and carried the window 63 points; a
  four-finger pinch in fired `zoom-to-fit` once at scale 0.839 and its flight
  landed; a four-finger rest of 400 ms became a `hold` that fired
  `center-window` on lift, refused by name; a three-finger pinch out became
  `pinch_zoom`; Control-Option with a three-finger swipe resolved
  `mod+3-finger-swipe`; Option with a three-finger swipe over a window became
  the inert `swipe_resize` with its note; and after `set-trackpad off` a swipe's
  begin answered `"gesture":null` and nothing moved.

Still unrun, and not shown by any of the above: real fingers on a trackpad;
that AppKit delivers indirect touches to the canvas panel, and every finger in
every event; the shell's touch forwarding, hold timer, magnify routing and
gesture sink in `main.m`, which have only been compiled; how the recogniser's
thresholds feel; what macOS does with the same fingers when its own three- and
four-finger gestures are on, or off; anything drawn.

### After review, 2026-10-09

The review changed four things: the launch delay (see [Momentum](#momentum)); a
move gesture drives and releases only the drag it installed; on a press the
shell ends the gesture before it cancels navigation; and it follows a cancelled
pan's end with `cancel_navigation`. The recogniser's rules did not change, and
its two known misreads are now written out at the top of
`trackpad-gestures.m`. Run again afterwards, with nothing saved and still **no
physical trackpad gesture**:

- `gesture_flow`, with the scenarios those changes added;
- the socket run above, one launch on a freshly seeded scene: the same answers,
  the same warnings and config error on stderr, the same landing values, exit
  status 0 and the socket removed;
- the nine recogniser-into-controller sequences against the rebuilt library:
  output identical to the first run's.

The two shell changes sit behind touches in `main.m` and have only been
compiled.

### Put together with camera motion, 2026-10-09

The two runs above were made on this change by itself, when a swipe's coast was
a tracker and a frame hook of its own beside the gesture, and its pinch a
formula of its own. Both are gone: the gesture commands now drive
[camera motion](MOTION.md), which was built at the same time, and the
[Dispatch](#dispatch), [Momentum](#momentum) and
[Differences](#differences-from-upstream) sections above describe the result.
What that changed for a gesture:

- a swipe's end 50 ms or more after its last update still launches, an emptied
  tracker, so its reply reads `needs_frames: true` and the next frame is at
  rest; before, nothing was launched and the reply read false;
- `drift = 0` coasts for one frame, as upstream's `MomentumState` does with it;
  before, it launched nothing;
- a flight armed during a coast stops it at once, not at the next frame, and a
  coast is stopped by everything [MOTION.md](MOTION.md#what-stops-momentum)
  lists, a wheel zoom and a grab install among them;
- a pinch from a pose below the dynamic minimum is pulled up to it;
- a move gesture arms the drag's edge pan;
- in the shell, a gesture's reply starts the same frame timer as every other
  motion, a press also cancels a scroll pan waiting to launch, the begin of a
  recognised swipe or pinch cancels it too and keeps that scroll's lift from
  sending a `pan_end` beside the gesture's own
  ([MOTION.md](MOTION.md#what-the-shell-owes)), and a magnify event is a
  gesture event only, never a `zoom_by` as well.

`gesture_flow`'s expectations changed where they had encoded the separate coast
(the first three points), and it gained the fourth and fifth, a pinch under a
pointer drag, and the comparison of a swipe's coast with the same deltas sent as
timed pans. Run afterwards, with nothing saved and still **no physical trackpad
gesture**:

- `gesture_flow` and `motion_flow`, and the build under `-Wall -Wextra -Werror`;
- the built app, one launch of about six seconds as `--windowed 1100x700` on a
  private freshly seeded scene, config and socket, driven through `Infinify
  msg`: a file holding camera-motion settings (`drift`, both pan speeds, five
  `[navigation.edge_pan]` keys, `zoom.trackpad_speed`) and a `[gestures]`
  override (`swipe_threshold`, both pinch thresholds, `"3-finger-swipe" =
  "none"`, rebound four- and five-finger swipes, a per-direction trigger and an
  on-canvas hold) loaded with nothing on stderr, and the bookmark it defines
  read back; `action set-trackpad off`, `on` and `toggle` twice each answered
  `ok`, and `set-trackpad maybe` upstream's message with exit status 1;
  `action toggle-cursor-pan` answered `ok` twice; a second file with other
  motion values and another override was reloaded with nothing on stderr and
  its bookmark read back; `pan-viewport right` moved the camera 100 points,
  `zoom-to-fit` went to `750 -390` at 0.28484848484848485 and back, and
  `camera 400 -250`, `zoom 0.5`, `home-toggle` (to `0 -0` at zoom 1 and back)
  and `pan-viewport right` (200 canvas points at zoom 0.5) landed on the values
  of the runs above; `center-nearest right` was refused by name; SIGTERM, exit
  status 0, socket removed. Neither the trackpad's state nor the cursor-pan
  flag can be read over the socket, so only the answers were seen.

Not run again: the recogniser-into-controller program, so the 95 accepted
events and the figures above (378 points, 56 frames of coast) are the earlier
library's. Everything behind a touch in `main.m` is still only compiled: the
merged reply handling, press path and magnify routing included.

### Merged with window navigation and managed windows, 2026-10-10

The three runs above were made on a tree that had neither
[window navigation](NAVIGATION.md#window-navigation-actions) nor
[window lifecycle](LIFECYCLE.md): `center-nearest`, `center-window` and
`cycle-windows` were still refused by name there, which is what those runs
record. On the tree that has all of it:

- a gesture's threshold or hold action goes through the one action dispatch
  with the gesture's `pointer` and the firing event's `held`, the new optional
  field of `gesture_update` and `gesture_end`; the four-finger swipe, the
  `mod` three-finger swipe and the two holds of the default table now run, and
  a swipe bound to `cycle-windows` holds its cycle open or commits it as a key
  binding does;
- that dispatch's prelude is one: it ends an open cycle before a non-cycle
  action and stops the output's momentum, for a key, an IPC request, a hot
  corner and a gesture alike;
- a move's drag is the one drag there is: a window that closes by itself, or
  gives way to a stand-in, ends it and disarms its edge pan, and the gesture
  goes on with nothing to move;
- in the shell, a gesture reply's focus request goes to the navigation
  coordinator, a fired `cycle-windows` arms hold-to-commit, a gesture's begin
  withdraws a native focus request still in flight and leaves a settled open
  cycle alone, and a press ends an open cycle, then the gesture, then every
  flight and coast.

`gesture_flow` gained those scenarios (see the list above) and its expectations
for the four-finger swipe and the hold changed from "refused by name" to what
the action does. Run afterwards, with nothing saved and still **no physical
trackpad gesture**:

- `gesture_flow`, `motion_flow`, the navigation, lifecycle, platform, config
  and IPC scenarios, the headless coordinator regression, and the build under
  `-Wall -Wextra -Werror`;
- the built app, one launch of 6.9 seconds as `--windowed 1100x700` on a
  private freshly seeded scene, config and socket, without Screen Recording
  access, driven through `Infinify msg`: a file with `[navigation] drift`, the
  pan speeds, two `[navigation.edge_pan]` keys, `zoom.trackpad_speed`, a
  `swipe_threshold` and three `[gestures.anywhere]` bindings (a named swipe
  bound to `cycle-windows forward`, a five-finger swipe, a three-finger hold
  bound to `focus-center`) loaded with no config line on stderr and its
  bookmark read back; `action set-trackpad off`, `on` and `toggle` twice each
  answered `ok`, and `set-trackpad maybe` upstream's message with exit status
  1; `action toggle-cursor-pan` answered `ok` twice with the camera unmoved in
  between; `center-nearest right` flew to the seeded window at `1950 0` and
  focused it, where the runs above saw it refused, and `center-nearest left`,
  `center-window`, `pan-viewport right` and `left` (100 points each),
  `zoom-to-fit` (to `750 -390` at 0.28484848484848485 and back) and
  `home-toggle` (to `0 -0` and back) landed exactly; SIGTERM, exit status 0,
  socket removed. Neither the trackpad's state nor the cursor-pan flag can be
  read over the socket, so only the answers were seen.

No gesture event reached that app: a gesture firing `center-nearest`,
`center-window` or `cycle-windows`, `held` on its events, hold-to-commit armed
from a gesture, a move's native focus request and the merged press path exist
there as compiled code and as the controller scenarios above, nothing more.
