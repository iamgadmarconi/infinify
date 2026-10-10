# Window sizing actions

DriftWM's sizing actions as controller policy: `grow-window`, `shrink-window`,
IPC `resize W H`, `fit-window`, `fit-window-snapped`, `fill-window` and
`zoom-to-fit-snapped`. Which size, which place, which camera and what a second
press restores are upstream's rules, read from malbiruk/driftwm
`352333a8fa1b22171492d4b71a54102045c9a19d` (GPL-3.0-or-later):
`src/state/{resize,fit,fill,cluster_snapshot,recenter,window_frame}.rs`,
`src/input/actions.rs` and `src/ipc/mod.rs`. The fill search, the cluster walk
and the push cascade are driftwm-core's `layout::fill::fill_rect` and
`layout::cluster::{cluster_of, adjacent_side, resolve_cluster_shifts}`,
upstream's own code. The controller code is `src/sizes.rs`.

Every sizing action is a canvas window's. What each does beside a
[widget, a screen-pinned window](RULES.md), a window rule's `size` and
[pick mode](POINTER.md#pick-mode) is under
[Widgets, screen-pinned windows and rules](#widgets-screen-pinned-windows-and-rules).

**No native window was resized to verify any of this.** See
[Verification boundary](#verification-boundary).

## The gate

Delivering a size to a real Mac window goes through the size-only
[native resize transaction](NATIVE_RESIZE.md), which exists in the shell only
when the app is started with `--experimental-native-resize`. That path has
never been proven on a live third-party window, so it stays an explicit opt-in
and nothing here makes it the default.

```json
{"op":"native_resize_capability","enabled":true}
```

answers `{}`. The shell sends it at startup, `true` and only with the flag: once
before it reads the config, because `bindings` marks the five actions
`implemented` only after it and a chord that is not implemented is never
registered, and again when it creates its resize coordinator, which is
redundant since the capability survives a `load`. It never sends `false`.
Between the first send and the coordinator no window has a bound source, so no
transaction can begin without a coordinator to perform it. `enabled` is a JSON
boolean; `0` or `1` is rejected. The capability is `false` until sent, is never
saved, and survives a `load`.

While it is `false`:

- `grow-window`, `shrink-window`, `fit-window`, `fit-window-snapped` and
  `fill-window` answer `action not implemented on macOS yet: <name>`, from the
  `action` command, a key or mouse binding, a gesture, a hot corner and IPC
  alike, and `bindings`, `mouse_binding` and `gesture_begin` report them
  `implemented: false`;
- the IPC `Resize` write answers
  `resize is not implemented on macOS yet: native layout resize is not available`
  for a canvas window. A widget and a screen-pinned window are refused first,
  in upstream's words, and that does not depend on the capability
  ([below](#widgets-screen-pinned-windows-and-rules));
- a window rule's `size` is recorded and named in `rule.not_applied`
  ([RULES.md](RULES.md#a-rules-size)).

Those replies are byte for byte what they were before this work:
`tests/sizes_flow.rs` compares them with the responses captured from the tree
before it. There is no other switch.

`zoom-to-fit-snapped` moves only a camera. It is not gated and always runs.

## What a sizing action does

Upstream writes a placement for the size it asks a client for, sends the
configure and lets the client answer whenever it does. Here an action **asks**,
and what upstream would have written for the size the window then has is
written **when the native result arrives**.

1. The action computes upstream's target size and a plan: where the window goes
   for the size it ends up with, and which restore state to record or clear.
2. If the window already has the target size nothing needs delivering: the plan
   is a logical placement, applied at once, as a `Move` is. `dirty` is true.
3. Otherwise a size transaction begins. The reply carries its `transaction` and
   `effect` under the keys `begin_native_resize` answers with, beside the
   reply's own `navigation`, `effects` and `dirty`. A reply that began no
   transaction has neither key.
4. The shell performs the effects and answers each with `native_resize_result`,
   exactly as for a drag. The transaction commits the size the window
   **actually** has: an `applied`, `clamped` or `rejected` setter commits what
   the window became.
5. On the first observation that has an attempted setter behind it, the plan is
   applied for that size: the placement, the snapped neighbours' shift, and the
   fit or fill restore state. A later read that finds yet another size places
   again, unless something else has moved the window since.

Every action reply path carries the two keys the same way: `action`,
`hot_corner`, `ipc` (beside `reply`) and the three `gesture_*` commands. The
`native_resize_result` reply itself is unchanged.

### The transaction is the existing one

A sizing action runs the same state machine as a drag: baseline read, setter,
final read, the same identity and generation checks, result validation and
uncertainty rules. It is started as a drag that was released during its
baseline read with one size queued, which that machine already handles.
`resize_transaction.rs` gained only:

- `begin_sized_resize`: the constructor for that state, taking a target size
  instead of a pointer. It cancels no camera flight (upstream's non-interactive
  resize cancels none) and does not require an acknowledged capture: no pointer
  is mapped through the picture, and a held key must not wait for a frame
  between two steps;
- `retarget_sized_resize`: a newer size takes the one latest-request slot, as a
  later `native_resize_to` takes it from an earlier one;
- `resize_slot` and `resize_answer`: read-only views for `sizes.rs`.

The interactive commands (`begin_native_resize`, `native_resize_to`,
`end_native_resize`, `cancel_native_resize`) behave exactly as before, and
`cancel_native_resize` applies to a sizing action's transaction too: a setter
not yet sent is dropped with its plan, one already sent is drained and its
result still applies the plan, since the window did change.

### What is asked at once

`fit-window` raises and focuses the window and flies the camera in the action
reply, not at the result. Upstream does both beside its configure, and neither
depends on the size the window then takes: the camera target is derived from
the window's center and the usable area alone. The `native_resize_result`
reply is left exactly as it was and arms no flight: it is consumed inside the
shell's resize coordinator, and what the shell does with the rest of it comes
a turn of the main queue later ([The shell](#the-shell)). If the transaction
then fails, the camera has still centered on the window.

A step, a fill and an unfit raise their window in the action reply, as
upstream's map does; no camera moves for them.

## The actions

All geometry is in upstream's whole logical pixels, taken from the world frame
rounded to the nearest pixel. Chrome is zero: a native frame includes its title
bar and has no compositor border. Nothing reads a native origin.

### `grow-window <dir>`, `shrink-window <dir>`

Upstream `step_resize_focused`. The focused window's named edge walks
`[navigation] resize_step` pixels outward, or inward for shrink; a diagonal
moves each of its two edges by `round(step / sqrt 2)`; an axis the direction
does not name keeps its size. The opposite edge stays where it is for whatever
size the window grants: the transaction is started on the edges the step moves,
so its own commit anchoring holds the others. That is where upstream ends up
once its `step_start_rect` has taken back what a client refused. Fit and fill
end when the window has answered, and so does the size a fit or fill would
restore ([below](#the-size-a-toggle-restores)).

### IPC `{"Resize":{window?,to?}}`

Upstream `cmd_resize`. Without `to` the reply is the frame's `Size`, as before.
With `to` the reply echoes the size asked for, and the window keeps its center:
the top-left moves by half the difference in whole pixels, toward zero. The
difference is measured from the size **last asked for** while the window's size
still reads as an answer to it (upstream `requested_element_size` and
`PendingResize::is_live`), so an identical request is a no-op rather than a
second shift. The place is written for the size asked: a window that grants
less keeps that top-left, as upstream's does. Refusals, in upstream's order:
the selector errors, `size must be positive`,
`this window has no canvas size to set: it is pinned, fullscreen, a widget, or not on screen yet`
for a widget and a screen-pinned window, and
`this window is under an interactive move or resize, or still settling one`
during a drag or resize gesture.

`Controller::request_window_size` is the entry point for any policy that sets a
size outright. A window rule's `size` goes through it when the window maps:
[RULES.md](RULES.md#a-rules-size).

### `fit-window`, `fit-window-snapped`

Upstream `toggle_fit_window`. A fit sizes the window to the **active** output's
usable area less `[snap] outer_gap` on every side, keeps its center, and flies
that output's camera to `round(window center - usable center)` at zoom 1, so the
frame lands exactly on the inset usable area. `focus_placement` plays no part.
The mode becomes `fit` and the size to come back to is saved
([below](#the-size-a-toggle-restores)). A window that takes another size than
asked is still fit, at the fit's top-left.

The second press is the unfit: the saved size comes back around the center of
the frame the fit **asked for**, taken at the top-left the window has by then
and truncated as upstream's `frame_loc_for_center` truncates. No camera moves.
The frame asked for, not the one the window took, is upstream's rule: it
measures a fit window by the size it last configured (`configured_window_size`),
which a client's own commit never rewrites. So a window that took less than the
fit asked, or refused it outright, still returns to where it was, and a fit and
unfit of it is the same round trip every time. The size asked for is kept with
the fit's restore point and is used for the unfit's center, for the frame the
snapped variant's neighbours are measured from, and for the frame a fill of a
fit window grows from.

The snapped variant also moves the window's snap cluster, upstream
`shift_cluster_around_primary`: each neighbour follows the edge it is snapped
to by that edge's whole-pixel travel, right and bottom neighbours in one pass
and left and top in a second, with upstream's cascade for whoever they push. A
shifted neighbour loses its fill restore point.

### `fill-window`

Upstream `toggle_fill_window`. The window grows in place inside the usable area
of the output that shows it, `outer_gap` from the area's edge and `[snap] gap`
from every other canvas window, stand-ins included, and an edge that sticks out
is pulled back. A widget and a screen-pinned window are no obstacle: upstream's
snap rectangles leave them out. No camera moves. A window no output shows, one wholly outside the
usable area and one that already fills its space are left alone, and nothing is
recorded. The mode becomes `fill`; the place the window had, the size to come
back to ([below](#the-size-a-toggle-restores)) and the view the fill ran in are
saved. A fill takes a window out of fit: it grows from the frame the fit asked
for, so a fit window alone on its output has nothing to fill and stays fit, and
it then restores the size from before the fit, around that frame's center.

The second press restores the saved frame.

### The size a toggle restores

Upstream keeps a `restore_size` per window: the size it had before a fit or a
fill changed it. A fit and a fill save that size and never replace it; only a
step, an IPC resize and a resize drag do. So a fit pressed on a filled window
saves the size from before the fill, not the filled one, and so does a fill
after a filled window was moved: no toggle loses the original size.

Here the value is captured when a fit or a fill first settles, from the size
the window had then, and dropped by a step or an IPC resize once the window has
answered, by a resize drag when it begins, and with the window's source. The
next fit or fill captures the size the window has by then.

`center-window` and `focus-center` on a window still filled return to the
camera and zoom the fill ran in, upstream's `RestoreFillElseReset`, instead of
the `focus_placement` point at zoom 1. The stored view applies only on the
output it was measured on, while the window sits where the fill put it and the
usable area keeps its shape. A [pick](POINTER.md#pick-mode) does the same when
that zoom is at or above `zoom.interact_min`.

### `zoom-to-fit-snapped`

Upstream `ZoomToFitSnapped`: `zoom-to-fit` over the focused canvas window's
snap cluster only, stand-ins included, with the same toggle back. A widget and
a screen-pinned window are in no cluster. With no focused window, or with a
widget or a screen-pinned window focused, and no return pending nothing
happens.

## Mode

`snapshot.windows[]` entries have `"mode"`: `null`, `"fit"` or `"fill"`. The
IPC `State` reply and event report upstream's `WindowInfo.mode`: `Normal`, `Fit`
or `Fill`. A window is never both.

What ends a restore point is upstream's list:

| | fit | fill |
| --- | --- | --- |
| the other toggle (`fill-window` on a fit window, `fit-window` on a filled one) | ends | ends |
| a step or an IPC resize, once the window has answered, or at once when the request was walked back to the size it has | ends | ends |
| a resize drag (`begin_resize`, `begin_native_resize`) | ends | ends |
| the window closes, becomes a stand-in or loses its source | ends | ends |
| `nudge-window`, IPC `Move`, `send-to-output` | stays | ends |
| a pointer or gesture drag, for the window and every member dragged along | stays | ends |
| being shifted as a neighbour by a snapped fit or a group resize | stays | ends |

**A fit survives a move.** Upstream clears only the fill restore point when a
window is re-anchored; the unfit then resizes around wherever the window is.

Restore points are ephemeral, as upstream's stage entries are: never saved, and
gone after a `load`.

## Widgets, screen-pinned windows and rules

Upstream asks `is_canvas_window` in every sizing arm, and so does this: a
window that is neither a widget nor pinned to a screen (`RULES.md`).

| | a widget | a screen-pinned window |
| --- | --- | --- |
| `grow-window`, `shrink-window`, `fit-window`, `fit-window-snapped`, `fill-window`, focused | nothing, no error (`step_resize_focused`, the three toggle arms) | the same |
| `zoom-to-fit-snapped`, focused | nothing, unless a return is pending | the same |
| IPC `Resize` write | `this window has no canvas size to set: it is pinned, fullscreen, a widget, or not on screen yet`, after `size must be positive` and before anything else, with or without the capability | the same |
| IPC `Resize` read | its size | its size |
| a size transaction (`begin_sized_resize`) | refused as `begin_native_resize` refuses it: `a widget is not moved or resized by hand`. No caller reaches it with one: each row above has passed it over or refused it first | `a screen-pinned window is not moved or resized by hand`, and the same |
| as an obstacle to a fill, a neighbour a snapped fit shoves, a member of the cluster `zoom-to-fit-snapped` frames | never: it has no snap rectangle (`snap_rect_for`, `Scene::snaps`) | never |
| `center-window`, `focus-center`, a pick | never the target, so no fill view is restored for one ([RULES.md](RULES.md#actions)) | the same |

- **Mode.** A widget never has a restore point. A fit or filled window that is
  pinned afterwards keeps its restore point, because upstream's `pin_window`
  clears neither: `snapshot.windows[].mode` still says `fit` or `fill`, the
  IPC `State` lists the window under `pinned`, which has no mode, every sizing
  action passes it over, and after the unpin the toggle undoes it. Its canvas
  frame follows its pin as the camera moves, and a resize drag of another
  window does not end its fill.
- **`send-to-output`.** The canvas leg re-anchors the window and ends its fill
  restore point. The pinned leg binds the pin to the other output and clears
  nothing, as upstream's `send_pinned_to_output` clears nothing.
- **A drag.** `begin_drag`, for a bound press, a pick-mode press and a move
  gesture alike, refuses in one place and in this order: a widget
  (`a widget is not moved or resized by hand`), a screen-pinned window
  (`a screen-pinned window is not moved or resized by hand`), and a window
  whose sizing action is still owed its size, alone or carried along by a
  cluster drag (`a native resize of window N is still pending`).
- **The pointer.** A size still owed holds the pointer exactly as a resize the
  pointer began: [`hover`](POINTER.md#what-holds-the-pointer) forwards no
  motion and moves no focus until the transaction has drained.
- **Pick mode.** Nothing here reads `zoom.interact_min`: `fill-window` runs
  below the threshold as upstream's does. What a pick then does with the fill
  view is [POINTER.md](POINTER.md#pick-mode).
- **A window rule's `size`** is asked of a new canvas window once it is placed,
  through `request_window_size`, when the capability is on:
  [RULES.md](RULES.md#a-rules-size). `preserve_aspect_ratio` and `fullscreen`
  stay recorded and not applied.

## A second action while a size is owed

There is one transaction. Upstream's rule for a window that still owes a
configure (`owes_a_configured_size`, `placed_element_size`) is that the next
request walks on from the size asked for. What maps onto the transaction's one
latest-request slot is done; the rest is refused, never queued:

- a step that moves the **same edges** as the pending step walks on from the
  size asked for and replaces the queued size. Its reply has no `effect`:
  nothing new is dispatched until the owed result arrives. A held key therefore
  steps at the repeat rate;
- an IPC resize of the window whose IPC resize is pending replaces it the same
  way, measured from the size already asked for;
- either of those two that brings the request back to the size the window
  already has leaves nothing to deliver: the transaction sends no setter for a
  size already committed and ends at its next read. What upstream writes at
  the request is then written at once, as for a window that already has the
  size asked for: an IPC resize's place, and the end of fit and fill;
- anything else, on that window or another, answers
  `a native resize of window N is still pending`: a step on other edges, a fit,
  a fill, a toggle, an IPC resize over a step. That includes every sizing
  action while a transaction is uncertain (`needs_observation`).

## Other interactions

- **A drag or resize gesture.** A gesture places its windows from its own
  anchors at every motion and holds the camera. Every sizing action is refused
  with `a window is under an interactive move or resize`; IPC resize uses
  upstream's own words.
- **A drag begun while a size is owed.** The result will place the window, so
  `begin_drag` of the window a sizing action is waiting on, or with `group` of
  a cluster that carries it along, answers
  `a native resize of window N is still pending` and changes nothing. Any other
  window can be dragged. `Move`, `nudge-window`, `begin_resize` and
  `begin_native_resize` were refused already, by the transaction's own guard.
  A transaction the pointer began keeps
  [its own rule](NATIVE_RESIZE.md): a world drag may run while its last read
  is owed.
- **A window that closes while its size is owed.** `window_closed` is refused
  while the effect is outstanding, as for a drag. The adapter then reports
  `missing_window`, the transaction fails, nothing of the plan is written, the
  close is accepted, and the next sizing action starts normally. The refused
  report logs no lifecycle event and the accepted one logs the close once
  ([EFFECTS.md](EFFECTS.md#beside-a-size-that-is-owed)).
- **A window the adapter will not resize** (`unsupported`): nothing is written
  and the source is marked `resize_disabled`, as the transaction marks it; later
  sizing actions on it answer `source resize unsupported`.
- **A baseline that differs** from the committed size fails the transaction, as
  for a drag, and nothing is written.
- **No focused window**, or a focused widget or screen-pinned window: the five
  actions do nothing, as upstream's do.

## The shell

`native/desktop/main.m` carries its side of this contract; its resize
coordinator and driver are unchanged.

- **Capability.** Sent as described under [The gate](#the-gate), in a normal
  run only: the fixture modes send nothing.
- **One hook.** Every `action`, `hot_corner`, `ipc` and `gesture_*` reply ends
  in `-applyReply:`, the pointer commands' (`hover`, `pick`,
  `pointer_nearest`) and an IPC `Screenshot`'s deferred one included. Its first
  step is `-consumeSize:`, the one place a size transaction leaves a reply: an
  `effect`, or an entry of `effects`, that is an `observe_resize_source` or a
  `resize_native_window` is handed to `-[DWResizeCoordinator consume:]`, which
  performs it and answers with `native_resize_result` as it does for a drag,
  and the transaction it names is remembered as the controller's own. In
  `-applyReply:` that `effect` is then taken out of the reply before the
  navigation coordinator reads it: that coordinator takes any `effect` for a
  focus request, and a reply that lists `effects` keeps its focus request
  there. A reply with no `effects` list, such as `activate`'s, `hover`'s or
  `pick`'s, keeps its `effect`, which is its focus request. Without a
  coordinator the hook does nothing.
- **A ruled attach.** The `attach` of a window whose rule names a size carries
  the transaction as `transaction` and a one-entry `effects`, its `effect`
  being the arrival's focus request. `-attach:logical:world:placed:` hands
  that reply to `-consumeSize:` once the source is registered, before the
  capture starts, and to `-follow:` as before.
- **Gates.** While the remembered transaction is the one in the slot and is
  not uncertain, an action is neither dropped nor preceded by
  `cancel_native_resize`, an IPC request is not answered `a native resize is
  pending`, and a pointer press is dropped without cancelling. That is what
  lets a held `grow-window` key, and the refusals above, reach the controller.
  Every other gate of an unresolved transaction stands (scroll, the start of a
  trackpad gesture, input forwarding, load, Return to desktop, quit), Escape
  cancels as it does a drag, and a transaction the pointer began or an
  uncertain one keeps all of its gates.
- **Failure.** A `native_resize_result` reply of a sizing action's transaction
  that has `failure` is shown as `Window not resized: <failure>`. The rest of
  that reply, less `effect`, goes through `-applyReply:` on a later turn of the
  main queue. The controller puts no `navigation`, `effects` or `dirty` there,
  so today that is a redraw and nothing more.
- **Saving and events.** The coordinator's existing changed callback saves
  once when a transaction has resolved, which covers what is written at the
  result; a plan applied at once is saved by the action reply's `dirty`. The
  same callback renders, which is what offers a State event to subscribers.
- No other reply begins a transaction: those of `window_closed`,
  `adoption_complete` and a retitle end in `-follow:` or nowhere, and carry
  none.

## Differences from upstream

- **When things are written.** Upstream places optimistically at the request;
  here size, place, restore state and neighbour shifts are written at the
  result, for the size observed. For a step the end state is the same. For a
  fit the window keeps its old frame until the native size arrives.
- **Size limits.** A native window's minimum and maximum are unknown, so only
  upstream's one-pixel floor is applied before asking; the window clamps, and
  what it took is committed.
- **Stand-ins.** Upstream resizes a stand-in's own frame for a step and for IPC
  resize, and configures the relaunched client to it. Here nothing can deliver
  a size at adoption, so both are refused:
  `<name> needs a live window: a stand-in has no native size to change` and
  `this window has no native size to set: it is a stand-in or has no live window`.
  `fit-window` and `fill-window` on a stand-in do nothing, as upstream's do.
- **One transaction.** Upstream sizes any number of windows at once; see above.
- **During a gesture** upstream bails only for the element under the grab, and
  silently for a step.
- **`restore_size`** ([above](#the-size-a-toggle-restores)) is read as
  upstream reads it, and kept by other bookkeeping. Upstream seeds it at a
  window's first commit; here it is captured at the first fit or fill, so a
  window that resized itself before that restores to the size it had then.
  Upstream sets it to the size a step or an IPC resize **asked for**; here
  those drop it and the next fit or fill captures the size the window took,
  which differs only when the window clamped the request. Upstream writes it
  when a resize drag settles; here the drag drops it when it begins, and no fit
  or fill can run in between.
- **The configured size** is kept only for a fit, as the size that fit asked
  for. Upstream reads the size it last configured in two more places: a fit
  pressed after a step, an IPC resize or a fill the window clamped centers on
  the frame that request asked for (and the snapped variant measures its
  neighbours from it). Here those center on, and measure from, the frame the
  window took.
- **Stacking.** IPC resize leaves stacking alone, as `Move` does here; upstream
  raises a client. The scene has no raise apart from focus, and a resize by
  selector must not take the focus. Neighbours shifted by a snapped fit keep
  their stacking.
- **A window that loses its source** loses its restore point, including one
  that is only detached and later rebound.
- **Fractions.** Upstream's frames are integers. A world frame with a
  fractional size is rounded for the policy and the size asked for is whole.
- **A pinned window is not sized at all.** Upstream resizes one in screen
  space by its resize binding; here no size transaction begins for a
  screen-pinned window or a widget, by hand, by action or by rule
  ([RULES.md](RULES.md#differences-from-upstream)).
- **A rule's `size`** is asked after the window is placed, not before, and not
  of a widget or a screen-pinned window: [RULES.md](RULES.md#a-rules-size).
- Fullscreen is not here: `toggle-fullscreen` stays
  `action not implemented on macOS yet`.

## Verification boundary

`tests/sizes_flow.rs` crosses the exported C ABI and JSON decoder. The test
plays the shell's part: it answers every resize effect with a synthetic
`native_resize_result`. Expected sizes, places and cameras are derived by hand
from upstream's rules on an output whose screen origin is not the global
origin, with `outer_gap`, `resize_step` and `focus_placement` set away from
their defaults. Nine of its thirty scenarios are the joins of
[Widgets, screen-pinned windows and rules](#widgets-screen-pinned-windows-and-rules):
the pass-over of a widget and a pinned window, a pin keeping a fit, what a
fill, a snapped fit and `zoom-to-fit-snapped` see, the three refusals of a
drag above and below `zoom.interact_min`, a size still owed holding the
pointer, a pick's return to a fill view, centring past a pinned window,
`send-to-output`, and a resize drag elsewhere. A rule's `size` is in
[`tests/rules_flow.rs`](tests/rules_flow.rs).

It establishes the controller's policy and wire behaviour. It does **not**
establish that:

- a resize effect resizes a native window, or that a real window reports the
  size the test said it took;
- the shell routes any reply to its resize coordinator, or performs an effect
  it is handed. The reply keys are the ones `-[DWResizeCoordinator consume:]`
  reads, and each test checks that the effect is the transaction's
  `pending_effect`, which `consume:` requires; nothing here runs that method,
  for an action's reply or for a ruled `attach`'s;
- a fit or a fill looks right on screen.

Upstream's own tests (`src/tests/window_mode.rs`, `src/tests/focus_placement.rs`)
were read for the contract and are not executed here.

### Built together and run, 2026-10-10

The controller and the shell were built into the app
(`scripts/build-app.sh`, ad-hoc signed, macOS 27.2, Apple Silicon) and the app
was launched twice as `--windowed 1100x700` on a private scene of three
detached placeholders, a private config and a private socket, and driven
through `Infinify msg`. Neither launch had Screen Recording access, so no
window on the canvas had a source. Nothing from them is saved as evidence.

- Without the flag, `action fit-window`, `fit-window-snapped`, `fill-window`,
  `grow-window right` and `shrink-window right` each answered
  `action not implemented on macOS yet: <name>`, and `resize --id 1 800 600`
  answered
  `resize is not implemented on macOS yet: native layout resize is not available`.
- With `--experimental-native-resize`, on the same placeholders, the three
  toggles answered `ok` and changed nothing, `grow-window right` and
  `shrink-window right` answered
  `<name> needs a live window: a stand-in has no native size to change`, and
  `resize --id 1 800 600` answered
  `this window has no native size to set: it is a stand-in or has no live window`.
  So the app does send the capability, and it holds after the scene load.
- In both, `State` reported `"mode": "Normal"` for every window, and
  `zoom-to-fit-snapped` on a focused window with one neighbour moved to the
  snap gap flew from camera `550 -318` at zoom 1 to camera `976 -450` at zoom
  `0.6056701030927835`, which is the center of the two frames' bounding box
  and (1100 - 2 x 80) / 1552 with `fit_padding = 80`; a second one flew back.

**No size transaction ran in the app.** A stand-in begins none, so the hook
handed nothing to the resize coordinator, `consume:` was never reached from a
sizing action, and no native window was read or resized. The shell's side of
[The shell](#the-shell) is compiled and read, not exercised, beyond the
capability and the reply paths those answers came back through.
[The shell notes](../../native/desktop/README.md#window-sizing-actions) list
what else is unrun.

### Built with rules, rendering and the pointer policy, 2026-10-10

After the sizing work was merged into the tree that has window rules, the
renderer and the pointer policy, the same checks were repeated on the same
machine. `tests/sizes_flow.rs` passed with 30 scenarios and
`tests/rules_flow.rs` with 22. A throwaway program outside the repository sent
the same requests, with the capability off, to the tree before the merge and
to the merged one, on a scene with a canvas window, a widget, a rule-pinned
window and a window whose rule names a `size`; of 168 raw replies and the
saved scene file, the only differences were `"mode": null` on every
`snapshot.windows[]` entry and `zoom-to-fit-snapped` reported implemented by
`bindings`.

The built app was launched again on three detached placeholders, with a
private scene, config and socket and no Screen Recording access. Without the
flag the five actions and the resize write answered the refusals quoted above,
`zoom-to-fit-snapped` framed a two-placeholder cluster at camera `2236 -0` and
zoom `0.6385869565217391` ((1100 - 160) / 1472) and returned, and a viewport
screenshot of that view was written and looked at. With
`--experimental-native-resize` the three toggles answered `ok` and changed
nothing, `grow-window right` and `shrink-window right` answered
`<name> needs a live window: a stand-in has no native size to change`, and
`resize --id 1 800 600` answered
`this window has no native size to set: it is a stand-in or has no live window`.

**No live window existed, so again no size transaction ran in the app**, by an
action or by a rule. The joins with widgets, pins, rules, hover and pick mode
ran only in the controller scenarios.
[The shell notes](../../native/desktop/README.md#what-has-been-run-for-sizing-with-everything-else-built-in)
have the commands and the answers.
