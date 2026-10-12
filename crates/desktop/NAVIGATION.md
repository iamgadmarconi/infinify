# Normal-window navigation, ABI 1

The `normal_window_navigation` snapshot capability covers a selected normal
window's camera placement with `keep` or `reset` zoom. The commands in the table
below are that primitive. Upstream's own window navigation (`center-window`,
`center-nearest`, `cycle-windows`, `focus-center`, and what a click or an
activation does) is built on it and described under
[Window navigation actions](#window-navigation-actions). Modal handling is
absent throughout, and fullscreen is [FULLSCREEN.md](FULLSCREEN.md)'s; the one fill rule, `center-window`'s and
`focus-center`'s return to a fill view, is described there. A widget and a screen-pinned window
([RULES.md](RULES.md#navigation-activation-gestures-and-outputs)) are no
navigation target anywhere on this page: `navigate_window` raises and focuses
one where it is and returns a null `navigation`, and no search picks one. No
native operation is performed.

| Command | Fields | Result |
| --- | --- | --- |
| `navigate_window` | `window`, `output`, `zoom_policy: keep / reset` | focus `effect` plus `navigation` |
| `cycle_navigate` | `output`, `backward`, `held` | existing frozen focus cycle plus Keep navigation; `{}` for empty cycle |
| `tick_navigation` | `timestamp_ns` unsigned monotonic nanoseconds | `changed_outputs`, `needs_frames`, `needs_pointer`, `clock_only` |
| `cancel_navigation` | `output` | `{}`; also stops that output's scroll momentum |
| `set_navigation_context` | `output`, `usable_rect_local`, `focus_placement`, `camera_speed`, `outer_gap` | `{}`; cancels that output's flight |
| `set_usable_area` | `output`, `usable_rect_local` | `{dirty}`; only the rectangle changes, see [The usable area](#the-usable-area) |

Navigation returns `{output,generation,target_camera,target_zoom,animating}`.
The generation is a controller-lifetime monotonic counter; load does not rewind it.
The response is the armed destination, not a claim of native focus success.
[Focus effects](FOCUS.md) remain separately acknowledged and superseded. A failed
or stale focus result never rewinds the camera. Invalid requests roll back all
logical focus, effects, flights, context, and frame-clock state.

The current pose lives only in `Scene.Viewport`. Snapshot `outputs` contains that
pose; `navigation.flights` separately shows optional camera/zoom targets, anchor
and generation. The target camera is cleared by the anchored zoom tick, because
that tick performs the camera movement itself. Flight entries disappear together
on arrival or cancellation. Context and clock are inspectable runtime state.
Scroll momentum, edge pans, cursor edge pan and the pointer zooms are the other
ways the camera moves; [camera motion](MOTION.md) covers them, the frame's
whole order and the snapshot keys they add.

The whole output, center placement, camera speed 0.3 and outer gap 0 are defaults.
Once a [config](CONFIG.md) is loaded, placement, camera speed and outer gap are
the config's (`focus_placement`, `navigation.camera_speed`, `snap.outer_gap`)
and only `usable_rect_local` is taken from this command. The shell does not
send this command, and sends a usable rectangle by no other either, so every
output is usable whole, and in a normal run an output is the whole display:
see [The usable area](#the-usable-area).
Usable rectangles use output-local coordinates, including their nonzero origin,
and must fit inside the output. Placement accepts center, top, bottom, left,
right, top_left, top_right, bottom_left, bottom_right. Speed must be finite in
`(0,1]`; gap finite in `[0,1e12]`. Frame coordinates remain fractional. A window's
world rectangle already includes its complete native frame/titlebar; additional
compositor border is zero. The internal alignment equation preserves upstream's
`outer_gap - border`, including negative insets, without exposing mutable chrome.
Oversize frames fall back to center separately on each axis.

Initialize the clock with `tick_navigation` before the first navigation and keep
it updated while idle; close marks and pending relaunches also lapse on it
([LIFECYCLE.md](LIFECYCLE.md#differences-from-upstream)). Every call computes one elapsed time for all outputs,
capped at 33 ms. The first call establishes the clock with zero elapsed time;
repeated timestamps use zero elapsed time, and decreasing timestamps reject
atomically. Arrival checks still run on zero-time ticks, as upstream does. A
native integration must schedule frames while `needs_frames` is true and apply
the resulting Scene placements; there is no native scheduling/input loop here.

`clock_only: true` conservatively guarantees that the successful tick and its
settlement changed no snapshot field except `navigation.clock_ns`. Pending
motion, pointer/trackpad grabs, hover requests, native sizing, fullscreen work,
close marks and relaunches keep it false. An empty `changed_outputs` alone does
not provide that guarantee. The normal transactional tick still runs. The Mac
adapter can retain its visual projection across this result while shallow-copying
the current clock into ordinary Snapshot replies; every other mutation drops
both caches. Native family geometry is reconciled separately, and capture
recovery, demand hysteresis and owed presentation retries still run while idle.

The source multi-output order is scroll momentum, edge pan, zoom tick, then
camera tick; a flight is the last two, with factor `1-(1-speed)^(dt*60)`.
The first two are [camera motion](MOTION.md)'s. A camera coasting after a
scroll, a drag pan or a [swipe pan](GESTURES.md#momentum) is one momentum, and
it and an armed edge pan are advanced by the same tick: their outputs are listed
in `changed_outputs`, and `needs_frames` stays true until every flight has
landed, every coast has stopped and no edge pan is armed. Arrival uses pre-tick displacement and strict thresholds:
zoom delta below 0.001 and anchor distance squared below 0.25. Keep also arms an
anchor and zoom target at the current zoom. Retargeting starts at the current
animated pose. Pan/zoom, timed pans, `zoom_by` and a bound trackpad swipe or
pinch included, and `cancel_navigation` cancel only their output; installing a
drag/resize, by pointer or by move gesture, cancels all outputs. A cancel takes
the output's momentum with its flight, see
[what stops momentum](MOTION.md#what-stops-momentum). Navigation during an active gesture rejects. Output re-registration
or disconnect cancels its runtime flight/context: a registration leaves the
output with the usable rectangle it carries, the whole output without one.
Reconnect uses its current or saved camera and never resumes a flight.

Save schema 1 is unchanged: saves contain current cameras, not destinations,
and no flight, clock, navigation generation, or context. Load clears all of these
runtime states (retaining generation monotonicity on the same handle).

## The usable area

Upstream's usable area of an output is the output less the exclusive zones of
its layer-shell panels and bars (`usable_area_on`, smithay's
`non_exclusive_zone`). A Mac has no layer shell. What stands over the canvas
there is the menu bar and the Dock, which macOS draws above the shell's panels.

**The shell sends no usable area.** That is the owner's decision of 2026-10-10:
the canvas covers each display edge to edge and reserves nothing for the menu
bar or the Dock. Windows may sit beneath them, and both stay visible on top.
Every output the shell registers is therefore usable whole, and each reader in
the list below measures the whole output. Upstream keeps a panel's exclusive
zone clear; this is a deliberate difference from it, not a gap that waits for
work.

The controller keeps upstream's rule all the same, for a caller that does send
a rectangle, and it is inert while none is sent. The rectangle is in
output-local points with the origin at the output's own top left:

| Command | Fields | Result |
| --- | --- | --- |
| `register_output` | `stable_id`, `screen_bounds`, optional `usable_rect_local` | `{output}`; the output starts with that rectangle, or with the whole output |
| `set_usable_area` | `output`, `usable_rect_local` | `{dirty}`; the rectangle is replaced in place |

The rectangle must have an extent and lie inside its output, edges inclusive;
anything else is refused with `invalid usable area`, and a registration refused
for it registers nothing. A registration always replaces what the output had,
so one without a rectangle is the whole output again, as every registration
was before the field existed. `set_usable_area` on an output that is not
registered is `unknown output`. Before any config is loaded it keeps the
placement, speed and gap `set_navigation_context` supplied. The rectangle is
runtime state like the rest of the context: in the snapshot under
`navigation.contexts`, never saved, gone with its output.

**A change moves nothing.** When a panel's exclusive zone changes, upstream
arranges its layer surfaces again and owes the output a frame
(`src/handlers/compositor.rs` `handle_layer_commit`,
`src/handlers/layer_shell.rs` `layer_destroyed`), and that is all: no camera,
window or pin is moved or clamped, and no animation is cancelled. Every reader
measures the area of the moment it reads. `set_usable_area` does the same: it
writes the rectangle, a flight keeps the anchor it was armed with and lands
where it was heading, and `dirty` is always `false`, because nothing a save
holds has changed. What does follow at once is what upstream derives once per
frame, the [active bookmark](IPC.md#bookmarks), which every accepted command
refreshes. Unlike `set_navigation_context`, it does not cancel the flight.

What measures the usable area, as upstream's callers of `get_usable_area`,
`usable_area_on` and `usable_center_screen` do:

| Reader | Upstream |
| --- | --- |
| a new window's place: the `focus_placement` point, the cursor clamp, the `auto` anchor nearest the usable center ([LIFECYCLE.md](LIFECYCLE.md#2-placement)) | `align_point_on`, `cursor_placement_pos`, `viewport_center_canvas` |
| where a window navigation parks a frame: `navigate_window`, `center-window`, `center-nearest`, `cycle-windows`, `focus-center`, `activate`, and where `send-to-output` lands one | `align_point_on` |
| the view anchor: `home-toggle`, `zoom-in`, `zoom-out`, `zoom-reset`, IPC `Zoom`, `go-to-bookmark`, `set-bookmark`, a `center-nearest` anchor point and its search origin, `center-window`'s nearest window | `usable_center_screen`, `viewport_center_canvas` |
| `zoom-to-fit`, `zoom-to-fit-snapped` and the dynamic minimum zoom | `fit_to_bbox`, `min_zoom` |
| `fit-window`, `fill-window` and the view a filled window returns to ([SIZES.md](SIZES.md)) | `compute_fit_geometry`, `compute_fill_geometry`, `fill_restore_view` |
| `send-cursor-to-output`'s point | `usable_center_for_output` |
| wholly or partly in view: a click's navigation, IPC `Focus`, the navigation after a close | `window_fully_in_viewport`, `window_intersects_viewport_on` |
| [cursor edge pan](MOTION.md#cursor-edge-pan) | `cursor_edge_pan_velocity` over the non-exclusive zone |
| the active bookmark | `refresh_ext_workspaces` |

And what measures the whole output, here as upstream: the clamp of a
[screen-pinned window](RULES.md#screen-pinned-windows) (`clamp_pin_frame` is
handed `output_logical_size` by every caller, so a pin may sit under a panel,
whatever rectangle the output holds), [fullscreen](FULLSCREEN.md) and the centring of a window that
keeps its own size, the at-home test of `home-toggle`, the share of a frame in
view (`center-nearest`'s anchor, `auto` placement's cluster test), the output
that shows a canvas point, a window drag's edge pan, IPC `Camera`, and the
picture a screenshot takes. Read again for this list: every upstream caller of
those three functions in `src/state` and `src/input`, and `clamp_pin_frame`
with its callers; the rest stand as their own pages document them.

On the Mac the counterpart of that rectangle would be the part of
`NSScreen.visibleFrame` inside the output. A shell file that read it, sent it
with every registration and sent `set_usable_area` when the Dock or the menu
bar changed it was written with these two commands and removed before it
landed, on the decision above. So the shell's `register_output` carries no
`usable_rect_local`, the shell never sends `set_usable_area`, in a normal run
as in a windowed one, and the renderer's coverage rule tests the whole output
([shell notes](../../native/desktop/README.md#the-usable-area)).

`usable_tap_flow` drives this through the exported C ABI on two outputs,
neither at the global origin, the first registered with what a Dock on the left
and a menu bar on top would leave of it: the refusals and the replacement rules; a new
window under `center`, `cursor` and `auto` placement with the cascade;
`center-window` on each of the nine `focus_placement` points of both outputs
with `snap.outer_gap`, a landing at another zoom, a frame too wide for the
area and a `center-nearest` anchor point; an IPC `Focus` of a frame that is all
on the output and partly under the Dock; `zoom-to-fit`, `zoom-to-fit-snapped`
and the minimum an IPC `Zoom` stops at; rule pins and a hand pin, which stay on the whole output; with the resize
capability the fit and fill frames, a filled window's view across a change of
the area, and a fullscreen window centred on the output; a change in mid-flight
compared snapshot to snapshot, the flight's landing, and the next action's; and
the numbers of two existing scenarios for an output with no rectangle. Expected
values are derived by hand from upstream's rules. Each rule was also changed in
the source once to see the tests fail, and restored: a registration that drops
the rectangle, an update that cancels the flight, one that validates nothing,
one that resets the context, a rule pin clamped to the usable area, a
fullscreen centred on it, and a usable area that is always the whole output.
That is controller evidence only: no screen's visible frame was read here.

The built app sends no rectangle, so what a launch can show is that an output
without one measures as it did. Launched on 2026-10-10 as `--windowed
1100x700` on a private scene, config and socket, first the build that still
held the shell's usable-area file and then the build that landed without it
gave the same: `msg state` the seeded placeholders and the output `windowed` of
1100x636 at camera `550 -318`, `action center-nearest right` settled on camera
`1950 -0`, and `action zoom-to-fit` on zoom `0.28484848484848485` at camera
`750 -390`, the numbers recorded for earlier builds on the same seed
([IPC.md](IPC.md#live-run-2026-10-09)), as in the last scenario above. No
normal run was made with either build. (Since desktop mode landed, later the
same day, that launch reads an output of 1100x700 at camera `550 -350`, the
whole window being the output; it settles on the same two poses, `1950 -0`
and zoom `0.28484848484848485` at `750 -390`:
[README.md](README.md#outputs-since-desktop-mode).) While the shell file existed, the two
commands were sent once in its own JSON by a throwaway program that linked the
release library with it: the display's output registered with the rectangle
read from `NSScreen` (the whole output on that display), and a rectangle 80
points shorter, made by hand, was taken by `set_usable_area`, after which
`set-bookmark` at camera `0 0` stored the centre of the shorter rectangle.
Neither the program nor the file is in the tree, and nothing from that run is
saved as evidence: the controller's side stands on `usable_tap_flow`.

## Evidence and limits

`navigation_flow` drives exported C ABI requests and compares trajectories to
verbatim methods mechanically extracted at test time from pinned full upstream
sources. Full-file SHA-256 and per-method line ranges/hashes are verified before
compilation. See [oracle provenance](tests/upstream/README.md). The shim supplies
storage/types and records side effects; it does not implement replacement
navigation equations. Tests cover Keep/Reset, all placements, asymmetric usable
areas, oversize frames, strict arrival boundaries, fractional native geometry,
60/120 Hz intervals, zero and capped intervals, retargeting, multiple outputs,
intermediate-camera hit testing, focus failure/supersession, cancellation, and
save/load. One pure helper test covers negative border inset, which native ABI
commands cannot express, against the same source oracle boundary values.

Parity claims apply only to source-representable traces. This executes selected
original methods, not the whole upstream compositor or its scheduler. It proves
no native rendering, capture, input delivery, or usable third-party compositing.

The shell supplies the frame timer and decides which launches drive these
commands and perform focus effects; see the
[shell integration scope](../../native/desktop/README.md). Nothing in this
crate executes native focus or proves real shortcut delivery.

## Window navigation actions

Adapted from `src/input/actions.rs` (`CenterWindow`, `FocusCenter`,
`CenterNearest`, `CycleWindows` and `execute_action`'s cycle prelude) and
`src/state/navigation.rs` (`navigate_to_window_on`, `fire_click_navigate`,
`activate_window_output_local`, `window_already_active`, `nav_center`,
`element_closest_point`) at the pinned commit. The directional search and the
visibility measures are `driftwm-core`'s `canvas::find_nearest`,
`visible_fraction` and `visible_canvas_rect`: upstream's own code.

Four action strings run through [`action`](IPC.md#action), and therefore through
key bindings, [hot corners](CONFIG.md#hot-corners) and `msg action`. Each one that lands does what upstream's
`navigate_to_window` does: it raises the window, makes it the logical focus,
asks for native focus with the existing [focus effect](FOCUS.md), and arms the
same per-output flight `tick_navigation` advances. All but `cycle-windows`,
which is itself a cycle step, end a cycle in progress first. The reply is `action`'s:
`{"navigation":…,"effects":[…],"dirty":…}`, with the focus effect in `effects`.
A detached placeholder is upstream's stand-in: it is a candidate and a target
everywhere below, it is focused and flown to, and it adds no effect.

| Action | Target | Zoom |
| --- | --- | --- |
| `center-window` | the focused canvas window; with none, or with a widget or a pinned window focused, the canvas window whose center is nearest the viewport center (the first in stacking order on a tie) | 1 |
| `center-nearest <dir>` | the best candidate in a 90° cone, see below | kept |
| `cycle-windows forward` / `backward` | the next step of the frozen focus history | kept |
| `focus-center` | the topmost canvas window under `pointer` on the active output | 1 |

"Nothing to do" is not an error: no window at all, no candidate in the cone, an
empty focus history, no `pointer`, or nothing under it reply
`{"navigation":null,"effects":[],"dirty":false}`. Every one of these needs an
output (`no active output` otherwise), rejects an unknown output, and rejects
with `navigation during active gesture` while a drag or resize is installed.

A [trackpad gesture](GESTURES.md) bound to one of these runs it through the
same dispatch as a key binding: `center-nearest` takes the direction of the
swipe, `pointer` is where the gesture began, and `held` is what the event that
fires the action reports.

- **`center-window`** is upstream's `RestoreFillElseReset`: a window still
  [filled](SIZES.md#fill-window) returns to the camera and zoom its fill ran
  in, and any other is flown to at zoom 1. `focus-center` is the same.
- **`center-nearest`**. The viewport center is the world point under the usable
  center, `camera + usable_center / zoom`. The origin of the search is the
  focused window's center when the whole frame is on the output (upstream's
  threshold 1.0, measured against the whole output, not the usable area), and
  the viewport center otherwise; in the first case the focused window is not a
  candidate. A focused screen-pinned window is never the origin, as upstream's
  is not. Candidates are every canvas window (no widget, no pinned window:
  upstream's `is_canvas_window`), represented by the point of its
  frame closest to the origin, or by its center when the frame contains the
  origin, and every `navigation.anchors` point inside the ±1e12 world. A
  candidate at offset `d` from the origin is in the cone of unit direction `u`
  when `d·u > 0` and `|d×u| ≤ d·u`; the lowest `|d|² / (d·u)` wins and the
  first candidate keeps a tie, windows in stacking order before anchors in file
  order. A window is navigated to with upstream's `NavZoom::Keep`. An anchor
  clears logical focus (so the next search starts from the viewport center,
  which is then that anchor), disarms a zoom-to-fit return and flies the camera
  until the usable center shows it, at the current zoom, writing only the
  camera target as `go-to-bookmark` does; there is no effect, and `dirty` is
  true when a window was focused.
- **`cycle-windows`** is `cycle_navigate`. The fresh-cycle anchor is the logical
  focus, as upstream's `cycle_anchor` is the focused window or stand-in: a
  focused window that is not the history's head (a placeholder never enters it)
  starts the cycle at the head instead of stepping past it. With `held` true
  the cycle stays open until `end_focus_cycle`; otherwise the step is released
  at once. Either way the history changes only when the selection's focus
  request is answered: confirmed by the adapter, or `focus_logical` from a shell
  that performs no native focus. See [FOCUS.md](FOCUS.md#upstream-entry-points).
- **`focus-center`** hit-tests `pointer` against the world rectangles of the
  canvas windows on `output` only. A screen-pinned window under the pointer is
  passed over, as upstream's walk skips it, so the canvas window beneath is
  taken; a widget is not taken. Upstream reads the seat's pointer; here the
  shell supplies it.

### `activate`

```json
{"op":"activate","window":3,"output":1,"cause":"click"}
{"op":"activate","window":3,"output":1,"cause":"click_release"}
{"op":"activate","window":3,"output":1,"cause":"native","identity":{…},"generation":7}
```

What upstream does when a window is clicked, or when something asks for it to be
activated. `output` is the active output or `null`. `identity` and `generation`
are optional; when present they must be the window's current binding, or the
command rejects (`stale source identity`, `stale binding generation`,
`unbound source`). For `click` and `native` the reply is
`{"effect":…,"navigation":…,"dirty":…}`:
`effect` and `navigation` as `navigate_window` returns them, the focus effect
or `null` and the armed flight or `null`, and `dirty` as `action` reports it,
true when focus or stacking was written and the shell should save.

- **`"cause":"click"`** is upstream's click-to-focus at the press: it ends a
  cycle, raises the window, makes it the logical focus and returns the focus
  effect (`null` for a placeholder). It never moves the camera, whatever the
  config says: `navigation` is always `null`, so the press and the drags that
  follow it reach the window where the pointer is.
- **`"cause":"click_release"`** is that press let go as a completed click.
  Upstream arms the click at the press and resolves it at the release
  (`arm_click_navigate`, `resolve_click_navigate`): the same button lifting
  within 5 px of the press, on the same output. The controller sees no pointer,
  so the sender decides that and sends this only then. Only with
  `navigation.auto_navigate_on_click` on, and only when the window still holds
  logical focus and its frame is not wholly inside `output`'s usable area, it
  flies there at the current zoom (upstream's `fire_click_navigate`). It
  requests no focus and writes none: the reply is
  `{"navigation":…,"dirty":false}` with no `effect` key, so that a shell does
  not read it as a focus change and withdraw the press's request while that is
  still in flight. `zoom.reset_on_activation` is not read. With `output` null
  it does nothing.
- **`"cause":"native"`** is for native focus the shell saw move to the window
  without being asked: upstream's activation request. The window must have a
  bound source. The observation is the focus, so `effect` is always `null` and
  nothing is asked of the adapter: the command ends a cycle, drops a pending
  effect, raises the window, makes it the logical focus, records it as observed
  native focus and promotes it in the focus history, exactly as
  [`observe_focus`](FOCUS.md) does, and then applies upstream's reveal rule. The
  home output is the first registered output whose viewport shows the frame's
  center, else `output`. A frame wholly on the home output is left where it is.
  A clipped one is flown to on the home output, at zoom 1, or at the current
  zoom with `zoom.reset_on_activation` off. With no output showing it and
  `output` null, only focus follows. Send it instead of `observe_focus`,
  not after it: a window that already holds both logical and observed native
  focus and is at least partly on its home output is upstream's "already
  active", and the command then changes nothing and replies
  `{"effect":null,"navigation":null,"dirty":false}`. So does the same report
  again for a window still wholly off its home output while that output is on
  the flight the first report armed: a repeat arms nothing
  ([LIFECYCLE.md](LIFECYCLE.md#event-delivery)).

For a widget or a screen-pinned window all three causes focus and none flies:
a `click` raises and focuses it and returns its focus effect, a
`click_release` answers a null `navigation` whatever the config says (upstream
arms no click navigation for a widget, and a pinned window has no canvas
position to bring into view), and `native` records the observed focus without
promoting it in the focus history and without a reveal.

A press that a mouse binding turns into a move or a resize of the window
under the pointer needs no `activate`. Upstream's `move-window`,
`move-snapped-windows`, `resize-window` and `resize-window-snapped` arms call
`raise_and_focus` and then install their grab, for a canvas window
(`on_pointer_button`) and for a screen-pinned one (`try_pinned_button`)
alike, and `begin_drag`, `begin_resize` and `begin_native_resize` do the
same in one command: the window is raised, takes the logical focus, and the
reply carries the focus request a `click` returns, null for a window without
a source. `begin_drag` and `begin_resize` answer `{"effect":…}`;
`begin_native_resize`, whose `effect` is its transaction's, carries it as
the one entry of `effects`. No camera moves and no click navigation is
armed. A begin that is refused changes nothing, focus included: a widget,
which upstream's arms pass over for the click-to-focus fallback, and the
refusals that are this controller's own ([below](#differences-from-upstream)).
On a fullscreen output the fullscreen ends first, as upstream's press ends
it ahead of the binding's arm: the exit, the focus, the grab
([FULLSCREEN.md](FULLSCREEN.md#the-order-of-a-grab)).

`{"op":"clear_focus"}` is upstream's click on empty canvas; see
[FOCUS.md](FOCUS.md#upstream-entry-points).

### Visibility

Two different tests are upstream's and both are kept:

- "Wholly inside the usable area" (`window_fully_in_viewport`): the projected
  frame against the navigation context's `usable_rect_local`, in fractional
  points. Used by a completed click (`click_release`) and by the IPC `Focus`.
- "Share of the frame on the output" (`visible_fraction`): against the whole
  output, panels included. Used by `center-nearest` (≥ 1) and by native
  activation (≥ 1 to stay put, ≥ `f64::EPSILON` to count as on screen).
  Upstream's function takes whole pixels. A fractional frame is measured by the
  largest whole-pixel rectangle inside it (origin rounded up, far edge down), so
  a frame navigation has just parked flush against an output edge still counts
  as wholly visible; a frame under a pixel across measures as invisible. The
  output's size is rounded to whole points. Geometry outside `i32` rejects with
  `view geometry exceeds integer range`, as the view actions do.

### Differences from upstream

- A window's representative points are taken from its world rectangle, which
  already includes the title bar: there is no separate chrome strip.
- Modal windows do not exist here, so none of upstream's special cases for
  them apply. A fullscreen window is no navigation target
  ([FULLSCREEN.md](FULLSCREEN.md#the-pointer-and-other-outputs)), and
  `center-nearest` has no just-exited-fullscreen anchor. Widgets and screen-pinned windows follow
  upstream's rules, with the differences
  [RULES.md](RULES.md#differences-from-upstream) lists: `focus-center` takes no
  widget, where upstream's would fly to one.
- Whether a release completes a click is the sender's to decide (upstream's
  5 px slop on the same output): the controller sees no pointer and checks only
  that the window still holds logical focus and is still clipped. Upstream also
  waits out the double-click window before panning after a click on a
  server-side title bar; there is no separate title bar here, so
  `click_release` always pans at once.
- `focus_follows_mouse`, `zoom.interact_min`'s pick mode and the pointer's
  `center-nearest` are the [pointer policy](POINTER.md). `auto_navigate_on_close`
  belongs to the [window lifecycle](LIFECYCLE.md#a-window-closes).
- A move or resize begin that is refused focuses nothing. Upstream's press
  raises and focuses the window and then starts its grab, and nothing there
  refuses the grab of a window its picker let through. Here a command that is
  refused changes nothing, so a window whose size is still owed, a pinned
  window asked to resize, a stand-in asked for a native resize and a second
  press during a gesture are left as they were. A shell that wants upstream's
  focus for such a press asks for it itself, with `activate` (cause `click`)
  or `focus`; the native shell does for a resize press that begins nothing.
- The focus history is promoted when a focus request is answered, not when
  logical focus is set: see [FOCUS.md](FOCUS.md#upstream-entry-points). A shell
  that performs no native focus answers `focus_logical`, and cycling then
  follows logical focus. If no request is ever answered the history stays empty
  and `cycle-windows` has nothing to step through; the three other actions and
  `activate` do not need it.

### Evidence and limits

`navigation_actions_flow` drives all of the above through the exported C ABI on
an output whose `screen_bounds` origin is not the global origin and whose usable
rectangle is asymmetric: `center-nearest` in the four cardinal directions and a
diagonal over a fixed layout with a placeholder and an anchor, with the origin
switching between the focused window and the viewport center, and over two
layouts in which the closest point and the center, and the cone score and the
plain distance, choose different windows; `center-window` with and without
focus; `cycle-windows` held and not held, committed by `end_focus_cycle` and by
the prelude of another action, with every request confirmed and with every
request answered `focus_logical`; `focus-center` with the pointer over a
window, over empty canvas and absent; `activate` for its three causes with
`auto_navigate_on_click` and `zoom.reset_on_activation` on and off, for
visible, clipped and off-screen windows; `clear_focus`; a
[hot corner](CONFIG.md#hot-corners) bound to `focus-center`, to `cycle-windows`
and to another action, with and without `pointer` and `held`, and the cycle
prelude of the output and layout actions; flights settled by
`tick_navigation`; and the identity each effect carries. Expected targets are
derived by hand from the rules above. Upstream's action bodies are not executed
as an oracle, so parity with them is by reading.

This is controller evidence only: synthetic identities, synthetic focus results,
no key, no pointer, no native window. It does not show that a chord fires an
action, that a modifier release is noticed, that a focus effect focuses
anything, or that a native focus change is observed.

The same commands were also reached through the built app on 2026-10-09: four
`--windowed` launches on a private scene, config and socket with three detached
placeholders, driven through `Infinify msg` (so through `ipc`, `Action` and the
shell's flight tick) and read back after each flight settled. `center-nearest`
landed where the cone and score rule say in each case tried: right, left,
up-right, up and down from a view moved below and above a window, a kept zoom
of 0.5, no candidate for up and down, an origin that fell back to the viewport
center when the focused window was off the output, an anchor from a config file
written while running (focus cleared), and the lower score winning between two
windows above that anchor. `center-window` ended at zoom 1 on the focused
window and, with focus cleared, on the window nearest the viewport center.
`cycle-windows` replied Ok and changed nothing, as an empty history requires:
no placeholder ever enters it. The four malformed specs answered upstream's
messages. No window had a bound source, so no focus effect was produced,
`held`, `activate`, `focus_logical` and `clear_focus` were not reached, and
`focus-center` was sent without knowing what was under the pointer. The
[shell README](../../native/desktop/README.md#what-has-been-run-for-navigation)
has the transcript's values. Nothing from those runs is saved as evidence.

## View actions

The same six handlers, and the bookmark actions, are also reachable by upstream
action string and IPC request: see [actions, bookmarks and IPC](IPC.md).

Six camera-only commands adapt upstream's `PanViewport`, `HomeToggle`, `ZoomIn`,
`ZoomOut`, `ZoomReset` and `ZoomToFit` (`src/input/actions.rs` at the pinned
commit, with `try_restore_overview`, `fit_to_bbox`, `zoom_to_anchored`, and
`min_zoom` from `src/state/navigation.rs`). They are ordinary ABI 1 commands with
no snapshot capability or flag of their own. Each arms the same per-output flight
that `tick_navigation` advances; none touches a window, a source, logical or
native focus, or another output.

| Command | Fields | Destination |
| --- | --- | --- |
| `pan_viewport` | `output`, `direction: up / down / left / right / up_left / up_right / down_left / down_right` | camera moves `pan_step / zoom` world points along the unit vector |
| `home_toggle` | `output` | world origin under the usable center at zoom 1, or back |
| `zoom_in` | `output` | zoom × `zoom.step`, at most 1 |
| `zoom_out` | `output` | zoom ÷ `zoom.step`, at least the dynamic minimum |
| `zoom_reset` | `output` | zoom 1 |
| `zoom_to_fit` | `output` | every window inside the usable area, or back |

The reply is `{"navigation":{output,generation,target_camera,target_zoom,animating}}`
when a flight was armed and `{"navigation":null}` when the action has nothing to
do. `target_zoom` is the flight's zoom target; for `pan_viewport`, which carries
none, it is the current zoom. Generations share the window-navigation counter.
An unknown output rejects, and every action rejects with
`navigation during active gesture` while a drag or resize gesture is installed,
before changing any state. A destination whose viewport would leave the ±1e12
world, camera or far corner, rejects with `navigation target out of bounds`
instead of arming a flight that no tick could apply. `navigate_window` and
`cycle_navigate` still check the camera only.

All geometry is logical: the output's current camera and zoom, its
`screen_bounds` size, the navigation context's `usable_rect_local`, and window
world rectangles. Observed or original native rectangles are never read. The
screen anchor is the usable rectangle's center in output-local points
(upstream `usable_center_screen`); the world point under it is
`camera + center / zoom`. Actions read the current pose, not a pending flight's
destination, with one exception below.

- `pan_viewport` keeps a pending camera target and adds one step to it, so
  presses made before a frame extend the destination instead of restarting from
  the partially animated camera. A pending zoom target and anchor are dropped:
  zoom stays where the animation had brought it.
- `home_toggle` is at home when `|zoom - 1| < 0.01` and the world origin is
  inside the whole output (edges inclusive). Away from home it remembers the
  current pose and flies to camera `-center`, zoom 1. At home it flies back to
  the remembered pose and forgets it; with nothing remembered it is a no-op.
- `zoom_in`, `zoom_out` and `zoom_reset` anchor the world point under the usable
  center. Step targets pass through upstream's `snap_zoom` (±0.05 around 1).
  `zoom_in` at zoom 1 still arms a flight to the same zoom, as upstream does.
- `zoom_to_fit` flies back to a remembered pose if one is pending. Otherwise it
  fits the bounding box of every canvas window, detached placeholders included
  and widgets and screen-pinned windows left out,
  centers the box on the usable center, and remembers the pose it left. With no
  windows it is a no-op.

The steps are the [config](CONFIG.md)'s `navigation.pan_step`, `zoom.step` and
`zoom.fit_padding`; upstream's defaults are 100, 1.1 and 80 screen points.
`zoom_to_fit` also fits the config's `navigation.anchors`, as points. The fit
zoom is `min((usable - 2·padding) / box)` per axis, clamped to `[0.001, 1]`;
the dynamic minimum is half the fit zoom, floored at 0.001, with upstream's 5×5
box at (-2,-2) when there are no windows.

`driftwm_canvas::policy` works in upstream's integer logical pixels and leaves
the rounding to its caller. A window's world rectangle becomes the smallest
enclosing integer rectangle: the origin is floored and the far edge ceiled, so
a fit never clips a fractional frame. Output and usable extents are rounded to
the nearest integer. A value outside `i32`, including a bounding-box extent,
rejects the command instead of saturating.

Return poses are runtime state per output, visible as `navigation.home_returns`
and `navigation.overview_returns` in the snapshot. A pending fit return is
disarmed by `pan`, `zoom`, a `zoom_by` that changes or retargets the zoom,
`navigate_window`, an armed `cycle_navigate`,
`pan_viewport`, `zoom_in`, `zoom_out`, `zoom_reset`, and leaving for home; only
`home_toggle` consumes a home return. Cancelling a flight, starting a gesture,
changing the navigation context, or re-registering a connected output leaves
both in place. Removing the output drops both. Neither is saved: save schema 1
is unchanged and load starts with none.

Differences from upstream:

- Upstream's pinch and pointer zoom clamp to the dynamic minimum, and so does
  `zoom_by`. The direct `zoom` command still accepts the static 0.001 floor,
  and windows that move can raise the minimum, so a pose can already sit below
  it. `zoom_out` is then a complete no-op (`{"navigation":null}`,
  fit return untouched) rather than a flight that zooms in.
- `HomeToggle`'s pointer warp is absent; its fullscreen legs (instant snap,
  fullscreen restore) are the `home-toggle` action's
  ([FULLSCREEN.md](FULLSCREEN.md#home-toggle)). Every Scene window that is
  neither a widget nor screen-pinned nor fullscreen counts as a canvas window.
- Upstream's `execute_action` prelude commits an in-progress focus cycle before
  any non-cycle action and stops scroll momentum. The six commands, sent
  directly, stop their output's momentum and leave logical focus and a held
  cycle exactly as they were; the same handlers reached through
  [`action`](IPC.md#action) run the whole prelude first.

### Evidence and limits

`view_actions_flow` drives the six commands through the exported C ABI and
`tick_navigation` until `needs_frames` is false, on an output whose global
origin is not (0,0) and whose usable rectangle is asymmetric, beside a second
output whose pose must not change. It checks the settled fit against Scene
placements and the 80 px padding, exact toggle returns, the fixed world point on
every zoom frame, extended pan destinations, each fit-return disarm except
`cycle_navigate` (which arms through the same path as `navigate_window`), the
`zoom_out` deviation, gesture, schema and out-of-world rejection, save/load and
output removal. Expected values are derived by hand from the contract above; unlike
`navigation_flow`, upstream's action bodies are not executed as an oracle, so
parity with them is by reading, not by differential test. The pure helpers they
call are covered by the canvas crate's `policy_flow`.

This is controller ABI evidence only. It shows no key binding, shell dispatch,
frame scheduling, native rendering, capture, or input delivery. The default
shell binds these commands to global shortcuts and ticks their flights once per
frame of the display (a display link; 60 Hz until 2026-10-10); the toolbar
buttons a normal run also had until 2026-10-10 went with its toolbar strip,
and the shortcut path is built but unrun. See the
[shell README](../../native/desktop/README.md).
