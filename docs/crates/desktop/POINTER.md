# Pointer policy: hover, sloppy focus, pick mode and the pointer's center-nearest

What DriftWM does with a pointer that moves, as controller commands: which
window the motion belongs to, `focus_follows_mouse`, the pick mode of
`[zoom] interact_min`, and the mouse binding `center-nearest`. The controller
sees no pointer. The [native shell](../../native/app/Navigation/README.md) reports
where it is and applies the answer; nothing here delivers an event, focuses a
native window or changes a cursor, and none of this crate's tests shows that
any of that happens.

The logic is in [`src/pointer_policy.rs`](../../../crates/desktop/src/pointer_policy.rs), which names
the upstream functions it follows.

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
| `hover_source` | `window`, exact `identity` and `generation`, `output`, global `screen`, optional `time_ms`, optional `forward_motion` (default false) | The same policy reply for a recipient freshly resolved by the native adapter |
| `pick` | `window`, `output` | `{effect, navigation, dirty}`, or `{navigation: null, dirty: false}` when the output is no longer in pick mode |
| `pointer_nearest` | `output`, global `screen` and `start` points, optional `held` boolean (default false) | `{navigation, effects, dirty}`, the reply of the `center-nearest` action |
| `hit`, `input` | `output`, global `screen` point; `input` also the expected `identity` | the reply and the hit object carry `pick` |
| `resize_border` | `output`, global `screen` point | `{border}`: null, or `{window, edges, snapped}` when the point is in a window's resize border. Read-only, see [The resize border](#the-resize-border) |
| `mouse_binding` | optional `pick` boolean (default false), beside its optional `window` ([RULES.md](RULES.md#pass_mouse)) | `{binding}`; a pick target never answers `passed` |
| `snapshot` | none | each entry of `outputs` carries `pick` |
| `load_config` | `path` string or null | the reply carries `focus_follows_mouse`, the value now in force |

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
  presentation is unsettled. Also over a window whose visibility change is
  pending, which a renderer still draws (`source_presentable`) and `hit` skips
  (`source_interactive`). The JSON null reaches an Objective-C shell as
  `NSNull`, not as a dictionary: the native shell reads it as no hit
  (`DWControllerHit`, `native/app/Desktop/DWControllerHit.h`), including on the
  renderer-ordered path, where an `NSNull` once raised in the event tap.
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

### Native recipients: `hover_source`

The native adapter can resolve a recipient that differs from the controller's
root-rectangle hit, including a popup visible beyond its parent. `hover_source`
requires the current source identity and generation, a known output, and a
finite point inside that output. The adapter must validate the exact native
recipient before asking for policy and again before delivery; the command does
not establish native ownership or return application-local coordinates.

The default `forward_motion: false` observes a native hover without reposting
motion already delivered by macOS. A captured view uses `forward_motion: true`
to request motion delivery after the ordinary pick and pointer-grab gates.
Its `hit` contains only the logical `window`; the adapter retains the exact
captured member for posting. For native widgets and screen-pinned panels this
can forward motion without requesting focus or changing application stacking.
For ordinary canvas windows, the existing hover-focus policy applies.

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
**Since DriftWM v0.20.0 it defaults to 0.5** (it was 0): with no config file, or
a file that does not set it, every output is in pick mode below 50% zoom, and
`interact_min = 0.0` turns it off. Nothing in this section changed for that
default except that it is now on: the logic is the v0.19 pick mode, and the
scenarios that run the three event classes under the default configuration are
[`crates/desktop/tests/interact_min_flow.rs`](../../../crates/desktop/tests/interact_min_flow.rs).

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

#### What the shell does with these answers

The controller answers per event; the shell decides what reaches an
application. Read from `native/app/Desktop/Desktop+Input.m`, `Desktop+NativeMouse.m`, `Desktop+NativeTitles.m`, `Desktop+CapturedInput.m` and `DWNativeInput.m` for this
update. Not run: neither on the owner's Mac nor in the UTM guest (the guest lock
was held by other lanes for the whole session, so the planned check, a click, a
drag and a scroll at zoom 0.4 over a Calculator window with `msg state` and
screenshots as evidence, was not made). The built bundle only proves that the
Objective-C compiles:

| Event below `interact_min` | Capture mode (an overlay with copies of windows) | Compositor mode (the real windows are drawn by the window server) |
| --- | --- | --- |
| **Press** | `hit` says `pick`, `input` is refused, so the press is never forwarded; the view's pick press (`pickPress:`) raises and focuses the target and arms the pick | the annotated tap's consumer (`consume`) claims the press (`claimed=pick`) and delivers it to the view's pick press, so the original packet never reaches the application. The early chrome tap refuses a pick (`DWNativeTitleRefused ... "pick"`) and leaves it to the late one |
| **Drag past the 5 point slop** | `pressDragged:` sends `begin_drag`: the window moves on the canvas | the captured button pair keeps owning the drag and release (`nativeGestureView`), so the drag is the same move and no drag tail reaches the application |
| **Click released within the slop** | `pick`: one navigation to the window at zoom 1 | the same, from the pair's release |
| **Scroll** | `mouse_binding` with `pick:true` is retried on empty canvas: a bare scroll pans or zooms; nothing is forwarded | claimed (`claimed=pick`) and delivered to the view, which pans or zooms through the same binding; the scroll never reaches the application |
| **Pen (tablet packets)** | not forwarded: the same `forward` check | **changed in this update**: dedicated tablet pointer and proximity packets over a pick target are taken by the tap (`Desktop+Input.m`, "Below [zoom] interact_min ... a pen's dedicated packets included"). Before, only the pen's mouse-subtype packets were the pick's |
| **Motion** | `hover` answers `forward: false`; the overlay does not deliver it | **dropped by the annotated tap** since 2026-10-30 (below): the consumer claims a mouse-moved packet over a managed native window that is a pick target, so the window server's own delivery of it to the application never happens. The canvas has had the motion by then (its hover, sloppy focus and cursor edge pan run from it, `-queueNativeHover:` and `-[DWPointerHover nativeMotion:]`), the cursor is the window server's and is not frozen. Measured in the guest, see below |

##### Motion below `interact_min`, compositor mode (2026-10-30)

The row above said a mouse-moved packet "is never offered to `consume`". That
was wrong: the annotated tap offers every mouse-moved packet to its consumer
(`DWNativeInput.m` `-handle:event:`, and `DWNativeInputTests.m` has always
dropped one the consumer claims), and `-[Desktop nativeInput:event:]` took it
for its own hover and then answered NO, so the window server went on delivering
it. What was not known was whether a tap that drops a mouse-moved packet
freezes the cursor. It does not (below). The consumer now answers YES for a
packet that is over a managed native window (the window server's own answer in
the packet, `kCGMouseEventWindowUnderMousePointer`, mapped to its root as every
other native path does) on an output in pick mode, unless the window is a
widget, a screen-pinned or a fullscreen one (the placement says which; the
controller's `hit` gives the same answer and is not asked, to keep the
per-packet cost nil). The decision is `DWPickMotion` (`DWControllerHit.h`),
run in `DWControllerHitTests.m` against the real controller's snapshot
and hit at zoom 1, 0.4 and exactly 0.5 and over empty canvas, a widget and
malformed input; the packet-level contract (a claimed moved packet is dropped,
an unclaimed one and one during a held native button are returned untouched, a
tagged one is not offered) is in `DWNativeInputTests.m`.

Measured in the UTM guest (macOS 27.0.1, compositor mode, default
`interact_min` 0.5, no config file), real HID events posted at the HID tap
with a small CGEvent program (200 plain mouse-moved events along a path inside
the window, then the cursor read back), over a fixture window with an
always-active tracking area that counts the `mouseMoved:` it is given (the
window server coalesces for a consumer that is slow, which this one is: it
writes a file per event, so 200 posted is about 70 delivered at best):

| Build | zoom 0.6 | zoom 0.4 |
| --- | --- | --- |
| before (the tree this change started from) | 71, 71 delivered | **69, 70 delivered** |
| after, runs of 200 events | 70, 71, 71, 72 delivered | **0, 0, 0, 0 delivered** |
| after, runs of 5000 events, zoom 1 / 0.6 / 0.5 / 0.4 | 284 and 294, 281 and 291, 288 and 291 delivered | **0 and 0 delivered** |

The cursor ended at the last posted point in every run (`CGEventCreate`'s
location and `msg cursor` both), at 0.4 as at 0.6: the drop freezes nothing.
Infinify's own CPU time over the 5000-event runs, before and after, at zoom 1,
0.6, 0.5 and 0.4: 1.10, 0.85, 0.95, 1.17 s and 1.09, 1.09, 0.87, 0.85 s (a
second run after: 0.72, 0.75, 0.76, 0.84 s), the spread between runs larger
than any difference. A first version asked the controller for a `hit` per
packet and cost 0.73, 1.03, 1.22, 1.60 s (about 75 microseconds a packet more
in pick mode); it was replaced by the placement lookup.

In Safari (a local page with three large links, `a:hover` red and a counter of
the page's `mousemove` events, window 900 x 640): at zoom 0.6 a 150-event path
over the links took the counter from 152 to 229 and left the link under the
pointer red; at 0.4, from a pointer parked off the window, the same path took
it from 151 to 152 and the pointer ended over a link that was not red. The one
event is the window server's own: when the pointer enters the window it sends
the application a mouse-entered event, which WebKit turns into a mouse move,
and no tap sees it; the link under the entry point stays red until the pointer
leaves (a hover state the page had before the zoom dropped below the threshold
likewise stays until the pointer leaves or moves in an application that still
gets events). The fixture, which counts only `mouseMoved:`, saw 0.

Not shown: a physical mouse or trackpad (the guest's events are synthetic, at
the HID tap, which the window server treats as hardware); the cursor's shape
over an application (it is the application's last request, and an application
that gets no motion cannot change it, so an I-beam or a pointing hand may
persist over a pick target; the canvas's pointing hand is drawn only where its
own panel is under the pointer); cursor edge pan and the canvas's hover during
the same motion (they run from the same packet before it is dropped; not
observed in the guest); a gaming mouse's packet rate; or a packet that arrives
while the output's view is crossing the threshold (the output list is the last
render's, one frame old at most).

A press that arrives with the Command/Control/Option chord of a held-modifier
binding is that binding's, as upstream's `try_pick_button` lets it be. A
screen-pinned window and a widget are no pick target and keep their pointer
(the table below).

##### focus-nearest on a press

`mod+ctrl+drag` is bound to `focus-nearest` since v0.20.0 (it was
`center-nearest`). `mouse_binding` answers kind `center_nearest` with
`"focus":true` for it, so the shell's NavigateGrab press is unchanged except
that it forwards the flag in `pointer_nearest` (`"focus": true`): the one action
the drag fires is then `focus-nearest <octant>`, upstream's
`MouseAction::FocusNearest`. `focus` defaults to false, and false is
`center-nearest` as before.

##### Sloppy focus after a pan, zoom or fling

DriftWM v0.20.0: with `focus_follows_mouse`, a pan, zoom or fling under a still
pointer moves focus to the window that lands under it; navigations keep the
focus they set. Upstream's `refresh_pointer_focus` pull is a per-frame check of
`hover_viewport` against the camera and zoom, gated by `hover_follows_camera`
(`user_moved_camera` raises it, a focus-setting navigation drops it). Here:

- `hover` stamps the view it answered for (the output, camera and zoom), on
  every path through it.
- A camera move the user drives (`pan`, `zoom`, `zoom_by`, an edge pan, the
  view actions, `msg camera` and `msg zoom`) un-parks the pull; a navigation
  that sets focus (`center-nearest`, `focus-nearest`, `focus-center`,
  Alt-Tab, `msg focus`, a fit, a bookmark's) parks it.
- `snapshot.navigation.hover_pull.needs_pointer` is true while
  `focus_follows_mouse` is on and the stamped view differs from the output's
  view, parked or not. The shell then reports the pointer each frame with
  `pointer` (it already does for cursor edge pan) and applies a reply with
  `dirty:true` and an `effect` exactly as a hover's (`Desktop+Navigation.m`, `-pointerFrame:`).
- `pointer` with a moved view and the pull un-parked is `hover` at that point:
  a window that landed under it takes the focus, without a raise. Parked, the
  new view is only stamped, so a later un-parking owes nothing for the
  navigation's own move.

Covered by `crates/desktop/tests/focus_nearest_flow.rs`
(`a_pan_under_a_resting_pointer_moves_sloppy_focus_and_a_navigation_parks_it`).
No Mac run: the shell half is three lines in `Desktop+Navigation.m` and was only built.

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

### The resize border

Upstream's `[mouse] resize_on_border` (default true): the band of
`RESIZE_BORDER_WIDTH`, 8 canvas units, outside a window's frame. The shell also
offers an inner band of five observed native points, with a minimum of three
display points and a cap of one quarter of each frame dimension. Capture pixel
density never determines its thickness. A left press in either band raises and
focuses the window and resizes it by that edge
(`decoration_hit_for`, `resize_margin_hit_for`, `resize_edge_at`). A native
frame already includes its title bar, so the band is around the whole frame.

`resize_border` answers for a press. A point over a window's frame can take
only that window's inner band; elsewhere the walk is upstream's z-order walk over the
canvas windows, topmost first, and the first whose band holds the point ends
it. `edges` is the side or corner the point
lies off, and `snapped` is `decoration_resize_snapped`, since an edge drag has
no modifier to ask for the cluster. It answers null with `resize_on_border`
off, in [pick mode](#pick-mode) (upstream's `try_pick_button` stands ahead of
the border), on a fullscreen output, in the interior beyond the inner band, and for a
widget, a screen-pinned window and a stand-in, which have no band here. The
shell begins the [resize grab](NATIVE_RESIZE.md#pointer-resize) with that
edge unless a binding whose modifiers are held claims the press on that
window, as upstream asks `modifier_button_binding` first.

Not adapted, by choice of the port and not for anything a Mac window cannot
do: upstream also counts the band as the window for the binding context and
for occlusion whether or not the option is on. Its topmost window's band
therefore covers a lower window's body (`decoration_under`, and
`surface_under` ends its walk on a band): a left press 4 units outside A's
edge over B beneath resizes A there, and here it is a click on B. And a point
of the band is canvas to `hit`, `hover` and `mouse_binding`, so a press the
border does not take is a canvas press, where upstream's alt+left there moves
the window and alt+right resizes it. A stand-in's band (upstream resizes a
stand-in's frame) and a pinned window's are not offered. The band is on the
canvas: a real window's own edges lie under the canvas panel and no pointer
reaches them. The inner band uses the same resize transaction as the outer
band, so the native application never receives an unscaled edge-drag tail.

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
- **Popups and menus are the window server's family, placed by transform.**
  Upstream draws a popup as a surface of its window, in canvas coordinates
  with the window's transform. Compositor (Dock-helper) mode has the same
  shape only for what the window server names a child of the window: a
  context menu, a pop-up button's or pull-down's menu, a combo box's list, a
  popover, a sheet, a child panel, a completion list, Chrome's omnibox list
  and hover card, Safari's address suggestions. Each is a family member, drawn
  at the window's scale at the window's offset, and takes pointer and
  keyboard input where it is drawn (zoom 0.5, 0.75 and 1; also after a zoom
  change while open). Before 2026-10-30 such a window was shown at its native
  place for 11 to 191 ms before the shell's first frame moved it; the helper
  now places it at the announcement (`docs/native/dock-helper/Payload/README.md`, "Arrival
  placement"). What is not this: a window with no parent in the window
  server (the global menu bar's menus, status items, and any popup an
  application opens without a parent) is left where the application put it,
  by design for the menu bar and unmeasured for the rest; a popup an
  application positions from the pointer's screen position instead of from
  its window is displaced (measured with a fixture panel: drawn 39 points
  left of and 77 below the pointer at zoom 0.5, because the window's offset is
  applied to a position already in drawn space; no standard popup measured
  does this). Tooltips could not be triggered in the guest, so no tooltip
  window was measured.
  [Measurements](../../native/app/CompositorMode/COMPOSITOR-MODE.md#popups-and-menus-of-a-transformed-window-full-desktop-dock-helper).
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
  the whole target for hover and for a hit; the resize margin exists for a
  press only ([The resize border](#the-resize-border)). Pinned windows and widgets do exist and are treated as
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
- in [`crates/desktop/tests/sizes_flow.rs`](../../../crates/desktop/tests/sizes_flow.rs), where a fill can be made
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
[shell notes](../../native/app/Navigation/README.md).
