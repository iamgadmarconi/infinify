# Pointer policy: hover, sloppy focus, pick mode and the pointer's center-nearest

What DriftWM does with a pointer that moves, as controller commands: which
window the motion belongs to, `focus_follows_mouse`, the pick mode of
`[zoom] interact_min`, and the mouse binding `center-nearest`. The controller
sees no pointer. The [native shell](../../native/desktop/README.md) reports
where it is and applies the answer; nothing here delivers an event, focuses a
native window or changes a cursor, and none of this crate's tests shows that
any of that happens.

Everything below is an addition to ABI 1: no existing command lost or changed
a field, and no existing reply lost one. The logic is in
[`src/pointer_policy.rs`](src/pointer_policy.rs), which names the upstream
functions it follows.

"The window under the pointer" is everywhere the layered hit of
[RULES.md](RULES.md#navigation-activation-gestures-and-outputs), the one `hit`
and `input` answer with: the windows pinned to the output, then the canvas
windows, then the widgets. What a [screen-pinned window or a
widget](#screen-pinned-windows-and-widgets) under the pointer changes is
collected in one place below.

## Commands

| `command.op` | Fields | Result data |
| --- | --- | --- |
| `hover` | `output`, global `screen` point, optional `time_ms` | `{dirty, pick, hit, forward}`, and `effect` when the focus moved |
| `pick` | `window`, `output` | `{effect, navigation, dirty}`, or `{navigation: null, dirty: false}` when the output is no longer in pick mode |
| `pointer_nearest` | `output`, global `screen` and `start` points, optional `held` boolean (default false) | `{navigation, effects, dirty}`, the reply of the `center-nearest` action |
| `hit`, `input` | unchanged | gain `pick` on the reply and on the hit object |
| `mouse_binding` | gains optional `pick` boolean (default false), beside its optional `window` ([RULES.md](RULES.md#pass_mouse)) | unchanged; a pick target never answers `passed` |
| `snapshot` | unchanged | each entry of `outputs` gains `pick` |
| `load_config` | unchanged | gains `focus_follows_mouse`, the value now in force |

### `hover`

```json
{"op":"hover","output":1,"screen":{"x":812.0,"y":431.5},"time_ms":734102}
```

Send it when the pointer moves over a canvas view with no button down and no
gesture in progress, at most once per displayed frame. Send it always: the
controller decides what, if anything, follows. An unknown output and a point
that is not finite are refused.

`time_ms` is when the motion is reported, in milliseconds on the clock the
`time_ms` of a timed [`pan`](MOTION.md#timed-pans-and-momentum) is on, and is
read the same way (a fraction is dropped, the value wraps at 32 bits, and one
that is negative or not finite is refused). It is optional and has one use:
telling whether a scroll that panned is still [holding the
pointer](#what-holds-the-pointer).

A hover stops nothing. Whether it moves the focus or not, no flight, no coast
and no pan waiting to launch is touched, and the camera goes on exactly as it
would have without it.

```json
{"dirty":false,"pick":false,"forward":true,
 "hit":{"window":2,"output":1,"identity":{…},"local":{…},"buffer_local":{…},
        "native_screen":{…},"requires_native_revalidation":true,
        "widget":false,"pinned":false,"pick":false}}
```

- `hit` is exactly the `hit` member of the [`hit`](README.md) reply for that
  point, or `null`: over empty canvas, outside the output, and where `hit`
  refuses, which is a stand-in (`unbound source`) and a source whose
  presentation is unsettled.
- `forward` says the motion is the window's. It is true when `hit` is not
  null, the hit is not a pick target, and nothing
  [holds the pointer](#what-holds-the-pointer). Upstream delivers
  motion to the surface under the pointer whoever holds the keyboard, so
  `forward` does not depend on focus or on `focus_follows_mouse`, and a
  widget's or a screen-pinned window's motion is forwarded like any other's.
  It is a statement about the scene, not an authorization: delivery still goes
  through `input` and the shell's own validation of the source, like a click.
- `pick` is true when a pick target is under the pointer (see
  [Pick mode](#pick-mode)). Over a stand-in that is `pick: true` with
  `hit: null`.
- `effect` is in the reply **only when sloppy focus moved the focus**. It is
  then the `focus_native_window` request that [`focus`](FOCUS.md) and
  `activate` return, to be performed and answered the same way, or `null` when
  the new focus is a stand-in. When the focus did not move there is no `effect`
  key at all, as in `activate`'s `click_release` reply and for the same reason:
  a shell that hands every reply to its focus coordinator must not read a null
  as "focus moved to something without a source" and withdraw the request in
  flight.
- `dirty` is true when the focus moved: logical focus is saved, as upstream
  arms its session write on a hover focus too.

### What holds the pointer

Upstream's hover focus and its pointer delivery both stand down while a
pointer grab owns input. `hover` answers `forward: false` and moves no focus
while any of these holds the pointer, on any output:

- a drag or resize gesture: `begin_drag` or `begin_resize` until
  `end_gesture`. The drag is whichever is installed, with the
  [edge pan](MOTION.md#edge-pan-while-a-window-is-dragged) it arms: a bound
  press's, a pick-mode press's, or the one a
  [move gesture](GESTURES.md#dispatch) installed;
- a native resize transaction that has not drained, whoever began it: a
  pointer's `begin_native_resize`, or the size a
  [sizing action](SIZES.md#widgets-screen-pinned-windows-and-rules), an IPC
  `Resize` or a window rule's `size` is still owed;
- a drag pan whose button is down, upstream's `PanGrab`: a timed `pan` with
  `source: "drag"` until its `pan_end`, or until `cancel_navigation`, however
  long the pointer rests in between;
- a trackpad gesture between its `gesture_begin` and its `gesture_end`,
  whatever it resolved to, an unbound one included. With the trackpad
  [off](GESTURES.md#set-trackpad) no gesture begins and none holds anything;
- a scroll that panned and whose momentum is yet to launch: a timed `pan`
  until its `pan_end` or anything else that stops that output's momentum.
  Upstream's own timer launches 50 ms after the last pan event whether or not
  the fingers have lifted, so with `time_ms` the pan holds the pointer only
  while the hover is less than 50 ms after its last event. A caller that ends
  every pan needs no time. One that may drop a launch does: the native shell
  gives up a scroll's launch when a swipe takes over its fingers, and without
  a time such a pan would hold the pointer until the next press or action.
  Without `time_ms` the pan holds until it is ended.

The last two are not grabs upstream, see
[differences](#differences-from-upstream). A coast, a flight, a `zoom_by` pinch
and [cursor edge pan](MOTION.md#cursor-edge-pan) hold nothing: upstream's
pointer motion runs `maybe_hover_focus` and then `refresh_cursor_edge_pan`, so
a pointer resting in the edge zone still focuses what the canvas brings under
it when it moves.

### Sloppy focus

With `focus_follows_mouse = true`, `hover` is upstream's `maybe_hover_focus`:

1. Off (upstream's default): nothing.
2. A pointer grab owns input: nothing. Here that is whatever
   [holds the pointer](#what-holds-the-pointer). An open focus cycle is held
   to be one as well, see [differences](#differences-from-upstream).
3. A window pinned to the output has the priority: upstream asks
   `pinned_window_under` before it looks at the canvas, and the hit here
   answers a pinned window first.
4. The window under the pointer takes the logical focus **without being
   raised**: stacking, frames, pins, cameras and flights are untouched.
   A stand-in takes it too, as upstream sets the focus intent on a suspended
   window; it has no native window, so its `effect` is null.
5. A widget is passed over (`hover_focus_window`), pinned or not: the focus
   stays where it is, and nothing beneath a pinned widget takes it.
6. Empty canvas keeps the focus where it is. Only a click there unfocuses
   ([`clear_focus`](FOCUS.md#upstream-entry-points)).
7. A window that already holds the focus intent is left alone, whatever became
   of its native request: upstream compares the intent, not the keyboard.

The request is `focus`'s own. The window enters the focus history when the
request is answered, by `focus_result` with `success` or by `focus_logical`,
which is this controller's rule for every focus
([NAVIGATION.md](NAVIGATION.md#differences-from-upstream)); upstream promotes
at once. Whether it enters at all is the one rule every focus follows
([RULES.md](RULES.md#screen-pinned-windows)): a screen-pinned window holds the
focus a hover gave it and stays out of the history. A hover never arms a
flight and is never followed by `auto_navigate_on_click`, which needs a click.

A config reload applies at the next `hover`; a request a hover already made is
still closed or expired under the echo rule below.

### The echo of a hover focus

A native window that a hover made key reports that it is, and a shell that
watches native focus sends [`activate` with cause `native`](NAVIGATION.md#activate).
For any other window that is upstream's activation: raise, and fly to it when
it is clipped. For a window a hover asked the adapter to focus it is that
hover's own request arriving as an observation, and upstream's hover neither
restacks nor moves the camera. So such a report is only recorded: the
observation is the focus, as for every native report, but where the window
stands. A pending request is dropped, as by every native report,
`observed_native` becomes the window, the window enters the focus history
(a canvas window; a screen-pinned one is recorded and stays out), and
the reply is
`{"effect":null,"navigation":null,"dirty":…}`. `dirty` is true when the report
is for a hover the pointer has since left, whose request outlived it: logical
focus then goes back to that window, again without a raise, and the next
`hover` over the window under the pointer asks for it again.

A hover's request is open, and a report for its window at the same binding is
its echo, until one of these closes it:

- it, or a later hover's request, is answered `focus_result` with `success`:
  the adapter read the keyboard back, so a later report is a new event;
- it, or a later one, is answered `focus_logical`: nothing was asked of the
  native window, so a report is the user's own activation;
- a focus request is made by anything that is not a hover (a click, an action,
  a cycle step, an IPC request);
- its echo, or the echo of a later hover, is recorded;
- 3 seconds have passed since the request was made, on the controller's
  `tick_navigation` clock, the one frame clock that also advances scroll
  momentum, edge pan and every flight ([MOTION.md](MOTION.md#frames));
  a host that never ticks has no clock and no expiry.

A request answered `focus_result` without `success`, or withdrawn unanswered
(`cancel_focus_cycle`, which a shell sends at every press), stays open until
then: the native window may take the keyboard after the adapter gave up, and
the shell's driver gives up after 1.5 seconds and reads native focus every
half second, or at a focus event and once a second where its observers are in
place ([LIFECYCLE.md](LIFECYCLE.md#the-apps-shell)). Nothing else closes it,
so neither `clear_focus`, `focus_lost`, a
reload that turns `focus_follows_mouse` off nor a native report for a window
no hover asked for does: inside those 3 seconds a deliberate activation of the
hovered window is still taken for the echo and neither raises nor flies, once.
The expiry is evaluated when a `hover` or a native report arrives, against the
last `tick_navigation` timestamp. At most 16 open requests are remembered. For
a window with no open request `activate` behaves exactly as before.
`observe_focus` is not changed and still raises; a shell that sends `activate`
first, as NAVIGATION.md asks, does not reach it for an echo.

### Pick mode

`[zoom] interact_min` is the zoom below which a window is too small to touch.
An output is in pick mode when the threshold is above 0 and its live zoom,
mid-flight frames included, is strictly below it (upstream `pick_mode`, per
output here). `snapshot.outputs[].pick` says so.

A pick target is the window under the pointer on such an output when it is a
canvas window, a stand-in included: the whole frame, title bar and all
(upstream's `pick_target_under`). A screen-pinned window and a widget are
never one, see [below](#screen-pinned-windows-and-widgets). `hit` and `input`
report a target as `pick` on the reply and on the hit object, `hover` as
`pick`. `hit` still refuses a stand-in as it always did; a shell that finds
stand-ins by itself reads the output's `pick` from the snapshot, and the
stand-in's `pinned` and `widget` from its placement.

- **No pointer input.** `input`, the validation every forwarded press, drag and
  scroll needs, is refused for a pick target with
  `pick mode: below zoom.interact_min a window takes no pointer input`, and
  `hover` answers `forward: false`. Every button is swallowed upstream, not
  only the left one.
- **The press** raises and focuses the target, as upstream's does: send
  `activate` with cause `click`.
- **Drag anywhere moves it.** `begin_drag` needs no binding and never did; send
  it without `group` once the pointer is past the 5 point click slop, then
  `gesture_to` and `end_gesture` as for a bound move. A stand-in moves the same
  way. `begin_drag` raises and focuses what it grabs, as a bound press does
  ([RULES.md](RULES.md#dragging-a-pinned-window)): for the target the press
  already took that restacks nothing, and the focus request in its reply takes
  the place of the press's, to be performed and answered like it. Upstream's
  promotion of the press to a move (`maybe_promote_pick`) asks nothing again,
  having one focus where this controller has a request per command. It is a
  window drag like any other: it is refused for a window whose
  [sizing action](SIZES.md#other-interactions) is still owed its size
  (`a native resize of window N is still pending`), installing it stops every
  flight and coast, a `pointer` on `gesture_to` arms its
  [edge pan](MOTION.md#edge-pan-while-a-window-is-dragged), it has a serial
  of its own, so a trackpad move gesture never drives it, and it ends with
  its window if that closes.
- **A left click picks.** Released within the slop on the same output, send
  `pick`. It is upstream's `resolve_pick`: `center-window`'s navigation, which
  raises and focuses the window and flies the camera until the frame sits on
  the `focus_placement` point at zoom 1. That carries the output back above
  the threshold, so a pick is one navigation and not a mode. If the output is
  no longer in pick mode at the release (zoomed in while the button was down)
  nothing happens and the reply is `{"navigation":null,"dirty":false}`. An
  unknown window or output is refused.
- **A filled window returns to its fill view.** A window still
  [filled](SIZES.md#fill-window) is not centered: the pick flies back to the
  camera and zoom its fill ran in, as `center-window` does for it, provided
  that zoom is itself at or above the threshold. `fill-window` also runs below
  the threshold, and restoring such a view would leave the output in pick
  mode with the click never reaching the window, a mode and not a navigation:
  upstream's `resolve_pick` asks `fill_restore_view` first and centers at
  zoom 1 when the stored zoom is below `zoom.interact_min`, and so does this.
  A stored view that no longer applies (another output, a moved window, a
  usable area of another shape) is the plain pick too. A fill needs
  the shell's `native_resize_capability`, so without it every pick is the plain one.
- **Bindings.** Pass `"pick":true` to `mouse_binding` when the pointer is over
  a pick target. A press is then the pick's unless a held-modifier binding
  claims it: a bare button bound in `[mouse.on-window]` answers
  `{"binding":null}`, and any chord with a modifier answers as usual. A scroll
  that finds no binding in the window context is looked up again in the canvas
  context, so a bare scroll over a pick target pans or zooms the canvas instead
  of dying on a window that cannot receive it. A wheel notch (`wheel_up`,
  `wheel_down`) is neither: upstream's notch site stands ahead of its pick
  handling, so the lookup is the plain one, a bare notch bound to an action
  included, and nothing is retried on the canvas. A pick target claims
  nothing by [`pass_mouse`](RULES.md#pass_mouse), whatever its rule and
  whatever `window` names. Without the flag the lookup is
  what it was. What the binding found then does is
  [camera motion](MOTION.md)'s like any bound scroll's: a timed `pan` that
  coasts from its `pan_end`, or a wheel `zoom_by`. A scroll that finds no
  binding in either context goes nowhere: `input` refuses the target, so it is
  never the application's.
- **Trackpad gestures do not read pick mode.** Upstream's gesture handlers
  (`src/input/gestures/`) never ask `pick_mode`, and its
  `try_start_gesture_move` takes the window under the pointer at any zoom.
  So `gesture_begin` resolves the same bindings below the threshold as above
  it, with the `context` the caller gives: a move gesture over a pick target
  focuses, raises and moves it, and a swipe or pinch pans or zooms. This is
  read from upstream's code; upstream's `interact_min.rs` scenarios drive no
  gesture, and none is driven here below the threshold either.

### Screen-pinned windows and widgets

[RULES.md](RULES.md) says what a widget and a screen-pinned window are. Under
the pointer:

| | A screen-pinned window | A widget |
| --- | --- | --- |
| which is under the pointer | on its own output it is hit before every canvas window, in screen space at its own size | hit only where no pinned and no canvas window is; a pinned widget is hit with the pinned windows |
| `hover`, `forward` | forwarded like any live window's motion | the same |
| `hover` with `focus_follows_mouse` | takes the focus, where it stands, before the canvas window beneath it; the request is answered like any other and the window stays out of the focus history | passed over: the focus stays where it is. Under a pinned widget nothing takes it |
| the echo of that hover | recorded where the window stands: no raise, no flight, no history entry | there is none: no hover asks for a widget's focus, so a native report for it is an [activation](RULES.md#navigation-activation-gestures-and-outputs) |
| below `interact_min` | not a pick target: `pick` is false on `hit`, `input` and `hover`, `input` passes, `forward` is true. Upstream's pointer focus (`pointer_focus_under_pick`) asks `pinned_window_under` ahead of the canvas and of its pick guard, and its button path asks `try_pinned_button` ahead of `try_pick_button`: a pinned window is drawn at its own size whatever the zoom and stays interactive. Its [`pass_mouse`](RULES.md#pass_mouse) claims a press as at any zoom, and no scroll or notch while its output is below the threshold | not a pick target either, with the same answers: the pick guard of upstream's focus cascade withholds the pointer from a non-widget canvas window only, and a widget is reached after it like at any zoom. Where a canvas window lies over the widget the cascade stops at that window and hands the pointer to nobody, so the widget gets nothing there: the hit is the canvas window, a pick target. A pinned widget is found with the pinned windows and keeps its pointer under the same canvas window |
| `pick` | does nothing: `{"navigation":null,"dirty":false}` | the same |
| drag anywhere | not pick mode's: no pick-mode press is ever on it. `begin_drag`, which the move binding sends, raises and focuses it and is its [screen-space drag](RULES.md#dragging-a-pinned-window) at every zoom, below the threshold too | `begin_drag` refuses it at every zoom, and focuses nothing |
| `pointer_nearest` | a press bound to `center-nearest` over it swipes as anywhere; the action's own rules for a focused pinned window apply | the same, with a focused widget's rules |

A pinned window lying over a canvas window keeps the press below the
threshold: the hit is the pinned window, so nothing there is a pick target.

### `pointer_nearest`

```json
{"op":"pointer_nearest","output":1,"start":{"x":780.0,"y":590.0},"screen":{"x":740.0,"y":590.0}}
```

A press bound to the mouse action `center-nearest` (upstream's default
`mod+ctrl+left`), which upstream turns into a `NavigateGrab`. `start` is where
the button went down and `screen` where the pointer is, both global screen
points.

- The drag pulls the canvas: the vector is `start - screen`. Dragging left
  goes to the nearest window on the right, dragging down to the nearest one
  above.
- Under 16 screen points nothing happens, a plain click included, and the
  reply is `{"navigation":null,"effects":[],"dirty":false}`.
- From 16 points on, the octant of the vector is the direction (a minor axis
  over 0.4142 of the major one is a diagonal), and the command is the
  [`center-nearest`](NAVIGATION.md#window-navigation-actions) action in that
  direction on `output`, with that action's reply. It runs once, through the
  one dispatch a key binding's, an IPC request's, a hot corner's and a
  gesture's action take, so the prelude is that dispatch's and runs once with
  it: an open cycle ends and the output's scroll momentum stops. `screen` is
  the pointer the action is given and `held` says whether a real modifier is
  physically down, as [`action`](IPC.md#action) takes them; `center-nearest`
  reads neither. Inside the dead zone no action runs, and no prelude either:
  an open cycle stays open and a coast goes on.

Upstream fires once, on the first motion that reaches 16 points, and ignores
the rest of the drag. The command decides from the two points it is given, so
a shell reproduces upstream by sending it once at that first motion. Sent at
the release instead, a drag that turned after leaving the dead zone goes where
it ended, not where it started, and one that came back inside the dead zone
does nothing, where upstream had already fired.

## Differences from upstream

- **The cursor cannot follow the application.** Upstream shows the cursor the
  client under the pointer sets. Here the pointer is over the shell's own
  panel, which owns the cursor; a forwarded motion does not bring the
  application's cursor shape back. Upstream's pointing-hand affordance over a
  pick target is the shell's to draw from `pick`.
- **Popups and menus open at the native window's place.** A forwarded motion
  or click reaches the real window where macOS keeps it, not where the canvas
  draws it, so whatever the application opens in response appears there.
- **An open focus cycle stops hover focus.** Upstream's guard is the pointer
  grab alone, and a hover during Alt-Tab would end the cycle and commit its
  selection. Here the selection stands until the cycle is released or
  cancelled.
- **A trackpad gesture and a scroll about to launch hold the pointer.**
  Neither is a pointer grab upstream, whose swipe pan, pinch zoom and scroll
  pan leave hover focus running for any pointer motion that arrives
  meanwhile. Here the gesture, and the scroll until its launch is due, stop
  hover focus and delivery, so that what the canvas slides under the pointer
  while the pad is busy takes neither. A move gesture is a grab on both
  sides: upstream's installs its move grab.
- **The focus history follows the answer**, not the hover, as with every focus
  here.
- **The echo rule** has no upstream counterpart: there, hover focus is the
  compositor's own and nothing reports it back. Until an echo or an answer
  arrives, logical focus and the native keyboard can differ, as after any
  focus request here.
- **The whole frame is the target.** A fullscreen window is kept apart from
  hover focus and from pick targets as upstream's is
  ([FULLSCREEN.md](FULLSCREEN.md#the-pointer-and-other-outputs)). Upstream
  also keeps layer surfaces apart, redirects
  hover focus to a modal child, and rejects a client's invisible resize
  margin. None of those exists here: the native frame, title bar included, is
  the whole target. Pinned windows and widgets do exist and are treated as
  [above](#screen-pinned-windows-and-widgets).
- **The pick-mode drag asks for the focus twice.** The press's `activate` and
  the drag's `begin_drag` each raise and focus the target and each return a
  request, the second replacing the first. Upstream focuses once, at the
  press. The scene is the same either way.
- **`pointer_nearest` is one decision from two points**, see above.
- **Per output.** Upstream's pick mode reads the active output's zoom; here
  each command names its output.
- Upstream's `pass_mouse` window rule, which lets a client claim a bound
  trigger, is asked by the same lookup ([RULES.md](RULES.md#pass_mouse)),
  with upstream's pick-mode gate: a pick target claims nothing, a
  screen-pinned window keeps its button claims below the threshold and loses
  its scroll and notch claims there. A widget that is not pinned keeps its
  claims below the threshold, where upstream's code drops them: the lookup
  is not told the pointer's output.

## Evidence and limits

`pointer_flow` drives all of the above through the exported C ABI on an output
whose `screen_bounds` origin is not the global origin and whose usable
rectangle is asymmetric:

- `hover` with sloppy focus off: the hit, `forward` inside a frame and not
  four points outside each edge, over a stand-in or off the output, and a
  snapshot that does not change;
- with it on: focus moving to a window that stays at the bottom of the stack,
  with windows, placements, outputs and flights compared whole; the request
  made once and not repeated; the history after `focus_result` and after
  `focus_logical`; the topmost of two overlapping frames; empty canvas; a
  stand-in;
- the guards under a drag gesture, a native resize and an open cycle;
- what else holds the pointer: a trackpad gesture that pans, one that is
  unbound and one that moves a window, each until its `gesture_end`; a drag
  pan a minute after its last event, until `pan_end`; a scroll pan at its last
  event and 49 ms after it, and without a time; a window drag with its edge
  pan armed. And what does not: the same scroll pan 50 ms after its last
  event, whose `pan_end` then launches the coast of an identical host that
  was never hovered; that coast, under three hovers that each move the focus
  while the camera stays frame for frame on that host's; a flight one frame
  in; and cursor edge pan, armed before the hover and after it;
- a native report after a hover focus, for a window that is clipped and lies
  under another one: while the request is pending, after the request failed,
  and for a hover the pointer had left for another window; and the cases that
  are not an echo (answered `focus_logical`, a later hover confirmed, sloppy
  focus off, a click in between), which raise and fly as before;
- the expiry of an open request, failed and withdrawn unanswered alike: 2.9
  seconds of ticks after the hover a report is still its echo, with sloppy
  focus since turned off and the focus cleared, and at 3.0 seconds it raises
  and flies;
- a reload turning `focus_follows_mouse` and `interact_min` on and off;
- pick mode at zoom 0.4 under a threshold of 0.5: `pick` on the snapshot, on
  `hit` and on `hover`, `input` refused, a drag of a window and of a stand-in
  with no binding, and `pick` landing a window and a stand-in under
  `focus_placement = "top-left"` with an outer gap at a camera worked out by
  hand; at 0.6, at 0.5 itself and with the threshold off nothing is a pick; a
  second output at zoom 1 is not in pick mode;
- `mouse_binding` with `pick`, for bare and modified scrolls and buttons;
- the layers: a pinned window hovered where it lies over a canvas window that
  tops the stack, taking the focus with nothing restacked, no pin and no
  camera moved, its answer and its echo leaving the focus history to the
  canvas windows, the same global point still its own after the camera
  panned, and the same native report without a hover raising it; a widget
  hovered alone (no focus, no request, the motion forwarded, a native report
  for it an activation), under a drag (not forwarded), under a canvas window
  (the canvas window takes the focus) and pinned over one (nothing does); and
  at zoom 0.4 under a threshold of 0.5 a pinned window over a pick target and
  a widget beside it, both `pick: false` with `input` passing and `forward`
  true, `pick` doing nothing with either; the same widget where a canvas
  window lies over it, where the hit is that window, a pick target, and
  neither takes input; the widget pinned over that canvas window, where it
  is hit first, `pick: false`, takes input and is forwarded its motion;
  `begin_drag` refusing the widget and dragging the pinned window by the
  pointer's own displacement, raised and focused by that press and still
  outside the focus history; and the canvas window still dragged and picked;
- the focus of a press that begins a grab: `begin_drag` and
  `begin_native_resize` on a window that is neither focused nor on top,
  each raising and focusing it with the request in its reply (`effect`, and
  the one entry of `effects` beside a transaction's `effect`), the focus
  history unchanged until the answer; below the threshold the pick-mode
  press's `activate` and then `begin_drag` on the same window, which
  restacks nothing and returns a second request, and a stand-in dragged the
  same way with a null request;
- in [`tests/sizes_flow.rs`](tests/sizes_flow.rs), where a fill can be made
  (the test answers the resize effects itself; no native window is resized):
  a pick of a window filled at zoom 1, from zoom 0.4 under a threshold of
  0.5, flying back to the fill's camera and zoom where the plain pick would
  park the camera 212 points away; a window filled at zoom 0.4 picked to
  zoom 1 while `center-window` on it restores the 0.4 view; `hover` holding
  the pointer, forwarding nothing and moving no focus, while a sizing action
  is owed its size; and `begin_drag` refusing a widget and a window owed its
  size, each in its own words, and dragging a pinned window in screen space,
  above and below the threshold;
- `pointer_nearest` in five directions, at the 16 point threshold, on both
  sides of the diagonal ratio, and inside the dead zone, each reply compared
  with the `center-nearest` action's on an identical scene; and with a cycle
  held open over a coasting camera, where the swipe ends the one and stops
  the other and leaves the controller exactly as the action given the same
  pointer and `held` leaves it, while a drag inside the dead zone leaves the
  cycle open and the camera coasting.

Expected values are derived by hand from upstream's rules; upstream's own
functions are not executed as an oracle, so parity with them is by reading.
Upstream's `hover_focus.rs` and `interact_min.rs` scenarios about server-side
chrome, client resize margins, layer surfaces and the cursor icon have nothing
to run against here and are not ported. The scenarios about pinned windows
and widgets above are not ports of upstream's either: they were written from
`maybe_hover_focus` and `hover_focus_window` as read, and for pick mode from
`pointer_focus_under_pick` with its focus cascade, `pick_target_under` and
`try_pick_button` (`src/input/mod.rs`, `src/input/pointer.rs`). Read against
those, `hit`, `input`, `hover` and the pick press needed no change: the
layered hit is the cascade's order, and `pick` is its guard.

This is controller evidence only: synthetic identities, synthetic focus
results, no pointer, no native window. It does not show that the shell
receives mouse-moved events on its panels, that it sends `hover` once per
frame, that a forwarded motion reaches an application or does anything there,
that a hover's focus effect makes a window key, that the echo of that focus is
what the shell then reports, that a pick-mode press is kept from the
application, or that the drag and release of a bound press are turned into
`pointer_nearest`. Those are the shell's to do and to show.

The shell as built sends every command and reads every field named here:
`hover` on pointer motion with `time_ms`, `activate` with cause `click` at a
pick-mode press, `begin_drag` past the slop, `pick` at the release,
`pointer_nearest` with `held` once at the first drag event 16 points from the
press, `"pick"` on each `mouse_binding` lookup, a button's, a scroll's and a
wheel notch's, `hit.pick` and
`snapshot.outputs[].pick`, and for a stand-in it finds by itself the
`pinned` and `widget` of its placement, which keep it from being a pick
target. It does not read `load_config.focus_follows_mouse`. That agreement is
by reading the two sides and by one build that links them, not by a run: the
built app was launched on 2026-10-10 and scripted through its IPC socket,
which has no pointer, so none of these three commands was driven there,
neither before this contract was joined to [camera motion](MOTION.md) and
[trackpad gestures](GESTURES.md), nor after, nor after it was joined to
[window rules](RULES.md) and [rendering](RENDER.md). What those runs did
show (both settings loading and reloading, upstream's two range warnings for
`interact_min`, the zoom crossing the threshold, a screenshot taken below it)
and everything they did not is in the
[shell notes](../../native/desktop/README.md#what-has-been-run-for-the-pointer-policy).
