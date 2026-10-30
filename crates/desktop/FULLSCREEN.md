# Fullscreen

DriftWM's fullscreen as controller policy: `toggle-fullscreen`, the window rule
`fullscreen = true` with its `output`, what leaves fullscreen and what that
restores, what a fullscreen output shows and what stays within the pointer's
reach on it, `[outputs.hot_corners] disable_when_fullscreen`, the translucent
rule, and fullscreen in the snapshot and in IPC `State`. The rules are
upstream's, read from <https://github.com/malbiruk/driftwm>
at `352333a8fa1b22171492d4b71a54102045c9a19d` (GPL-3.0-or-later):
`src/state/fullscreen.rs`, `src/input/actions.rs`, `src/state/recenter.rs`,
`src/state/placement.rs`, the fullscreen lines of
`src/state/{navigation,output,viewport,persistence,session_store}.rs`,
`src/input/{mod,pointer}.rs`, `src/input/gestures/*.rs`, `src/ipc/mod.rs` and
`src/handlers/{xdg_shell,compositor}.rs`, and its tests
`src/tests/{fullscreen_centering,fullscreen_handoff,fullscreen_exit_cost,translucent_fullscreen}.rs`.
Which action ends a fullscreen first is driftwm-core's
`Action::runs_during_fullscreen`, upstream's own code. The controller code is
`src/fullscreen.rs`, with hooks where the other modules meet it.

The window stays on the canvas's Space and is resized to its output. Same-Space
Fill and restoration have been exercised with real TextEdit and Safari windows
in the macOS 27 VM. These checks do not establish every policy or application's
behavior; see [Verification boundary](#verification-boundary).

## The gate

A fullscreen window is resized to its output, and delivering a size to a real
Mac window goes only through the size transaction of [SIZES.md](SIZES.md),
which exists only when the shell reported `native_resize_capability`. Every
normal run reports it, in [readback mode](NATIVE_RESIZE.md#readback-mode); a
controller nobody told anything does not.

While the capability is `false`:

- `toggle-fullscreen` answers `action not implemented on macOS yet:
  toggle-fullscreen`, from the `action` command, a key or mouse binding, a
  gesture, a hot corner and IPC alike, and `bindings`, `mouse_binding` and
  `gesture_begin` report it `implemented: false`;
- a window rule's `fullscreen` is recorded and named in `rule.not_applied`, and
  its window is placed, focused and flown to like any other;
- no output is ever fullscreen, so nothing else in this document can happen.

`tests/fullscreen_flow.rs` compares these replies with literals recorded from
a tree that had no fullscreen, for a shell that never sent the capability and
for one that sent `false`. Where a later change altered one, the literal is the
later tree's: a key binding's `bindings` entry gained `passable` with
pass-through. The snapshot gains `outputs[].fullscreen`, which is then `null`.

## Wire contract

| Where | What |
| --- | --- |
| `snapshot.outputs[]` | `"fullscreen"`: `null`, or `{"window": ID, "backdrop": "black" \| "canvas"}` |
| `snapshot.windows[]` | `"mode"` gains the value `"fullscreen"`, which stands over the `fit` or `fill` that survives beneath it. `pinned` is `null` while the window is fullscreen: its pin is put away |
| `snapshot.placements[]` | a fullscreen output has exactly one placement, its fullscreen window's, with `"fullscreen": true`. No other placement has the key |
| `action`, `hot_corner`, `tap`, `ipc`, `gesture_*` replies | an enter, and an exit, carry the size transaction under `transaction` and `effect`, as a sizing action does |
| `activate`, `pick`, `clear_focus` replies | may gain `transaction` and an `effects` list: see [A size that is owed](#a-size-that-is-owed). A `hover` reply never does |
| `attach` reply | a rule's `fullscreen` carries its transaction as a rule's `size` does: `transaction`, and its effect as the one entry of `effects`. `navigation` is `null` |
| `home_toggle` reply | the direct command's return into fullscreen carries its size transaction under `transaction` and `effect`, as the action's reply does, and its focus request in an `effects` list. Every other `home_toggle` reply is unchanged |
| IPC `State` | `fullscreen` lists one `{id, output, app_id, title, pid}` per fullscreen output (`pid`, v0.21.0, left out for a window with no bound source), sorted by output name and app id, and such a window is left out of `windows` |
| `rule.not_applied` | no longer names `fullscreen` for a window whose rule's `fullscreen` was applied as it mapped |
| `begin_drag`, `begin_resize`, `begin_native_resize` replies | unchanged in shape: the focus request of the window the grab takes, asked after the fullscreen has ended ([the order of a grab](#the-order-of-a-grab)) |
| `mouse_binding` | a fullscreen window named as `window` claims by its `pass_mouse` whatever `pick` says ([RULES.md](RULES.md#pass_mouse)) |
| `snapshot.pass_keys`, `snapshot.lifecycle_events`, a placement's `decoration.blur` | follow a fullscreen window as they follow any other: [RULES.md](RULES.md#pass_keys), [EFFECTS.md](EFFECTS.md) |

### The fullscreen placement

`screen_rect` is in global screen points at zoom 1: the output's
`screen_bounds` origin plus how far the window sits from the camera its output
is parked at, at the window's own size. For a window that took the size it was
offered that is the output's rectangle exactly. It does not depend on the
output's camera or zoom, and it is computed from the world rectangle, the
output's `screen_bounds` and the parked camera alone. `clip_rect` is its part on
the output, `world_local_crop` that part in the window's own points.

Its `decoration` is upstream's DrawnChrome for a fullscreen window: `mode`
`"none"`, `border_width` 0, `corner_radius` 0, `shadow` false. `opacity` is
upstream's `effective_opacity` with `is_fullscreen`: 1 unless the window's rule
or an IPC `Opacity` pins a value; `blur` is `effective_blur` with it: only a
rule's own `blur`.

`backdrop` is upstream's `fullscreen_conceals_canvas`. `black`: the window
conceals the canvas, and the output clears to black around and behind it.
`canvas`: the window's rule opacity (or IPC `Opacity`) is below 1, so the
background and the outlines of the other outputs keep drawing under it. Either
way no other window, no widget and no pinned window is drawn on that output.
A window that under-fills its output conceals all the same.

The native presenter retains the configured background behind physical windows,
including during fullscreen, so the menu-bar band and any uncovered margins do
not become black. Capture-mode fullscreen keeps the upstream backdrop policy.

## Entering

`toggle-fullscreen` is upstream's arm:

1. the focused live window, if it is fullscreen anywhere, leaves it;
2. else the active output's fullscreen ends;
3. else the focused window enters, on the output upstream resolves: its rule's
   `output` when that is connected, then the output of its pin, then the
   active one.

A widget never enters. A stand-in is no client: with one focused only leg 2
runs. Neither is an error, as upstream's is none.

Entering does, at once and in upstream's order:

- saves the window's place, the size it comes back to, the output's camera and
  zoom, and the window's pin;
- marks the output fullscreen, as upstream marks it before its configure;
- parks the output: camera rounded to whole pixels, zoom 1, no flight, no
  momentum, no edge pan, no zoom-to-fit return;
- puts the window's top-left at that camera, raises and focuses it (the focus
  request is in the reply's `effects`);
- asks the output's whole size of it, through a size transaction.

The enter's setter carries an optional `native_action:"fill"` preference for
a capable native shell to use the application's same-Space Fill action. It is
absent on reads and restores. The baseline, application-granted size handling
and exact native-frame restoration remain the same; emitting this preference
is not evidence that an app's Fill action or animation is available.
In desktop native mode the shell uses the verified `_zoomFill:` menu action,
withholds helper placement during the native transaction, then rebinds the
observed native bounds and requires a fresh placement ACK. The original helper
restore journal stays enrolled throughout. A verified unmodified title-bar
double click invokes this same fullscreen toggle; its complete second button
pair is consumed, while the first click retains ordinary canvas drag behavior.
This binding does not read or change the user's global double-click preference.
Actual animation quality remains a live-app acceptance check.
Native Fill accepts aligned native/displayed frames and now attempts a bounded
translation-only rebase for a freshly audited root-only family at unchanged
extent. It preserves the original native restore frame, uses one position write
inside a screen-update hold, acknowledges a neutral helper transform and its
subsequent omission, then releases the hold before Fill.
For scaled root-only windows and their restores, the shell captures a fresh raw
window image and holds it in a noninteractive AppKit panel. It acknowledges
alpha-zero, a neutral transform, and omission before changing the hidden native
frame. The panel uses AppKit's frame animator and resize duration, then remains
visible until the native reveal and normal placement are acknowledged. Restore
sets the saved native frame directly: a second native Unfill animation can finish
after its readback and overwrite a corrective frame write. Attached families or
unavailable capture retain the ordinary size path. Session, binding, output or
camera changes cancel the handoff. Headless checks do not prove visual quality;
animation and restoration require real-app validation.

When an exit also starts a camera flight to another window, the shell defers the
initial native read until that exact flight lands and its placement is
acknowledged. The wait retains the original transaction and validates the live
source, output and session throughout. No capture or native worker starts during
the flight. Replacement or cancellation retires the unstarted read; after
landing, placement readiness and native work retain their bounded deadlines.
Presenter lookup uses the shell's bound identity, while the controller effect
remains unchanged (its serialized identity also contains `owner:null`).

The 2026-10-22 real TextEdit-to-Terminal check completed Restore on its first
attempt at both default and slower camera speed. The default run reached the
restored world frame in 1.34 seconds, versus 3.68 seconds before the ordering
fix; these are single workflow timings including IPC and polling, not animation
frame-rate measurements.

If an unobserved refusal ends that transaction before any native mutation,
including a successful baseline followed by a Fill handoff refusal, the provisional
fullscreen is undone: the saved world position, camera, zoom
and pin return, other windows become visible again, and the result reports the
failure. No new native resize is owed by that failed enter. A native frame still
owed from an earlier fullscreen exit, or a size owed by the window's rule,
remains owed. This differs from a window
that was successfully observed and then grants or rejects the requested size;
that answer retains fullscreen at the size the application actually has.

The exit keeps the exact world top-left from before entry. The enter's fresh
native baseline supplies the original native origin and extent, including
fractional dimensions; a size change that the shell has not yet published replaces
the stale extent in the restore record. An explicit rule's deferred `size` remains
the exit target instead of the baseline extent. Fit and fill state survive a
fullscreen, but their requested sizes do not replace the native size actually
observed before entry. No minimum-size substitute or whole-pixel rounding is
applied to the restore extent.

A pinned window does enter: its pin is put away and the exit pins it again.
While it is fullscreen IPC `Pin` reads `false` and a write answers
`fullscreen windows can't be pinned`.

### Alignment

Until the window has answered the size it was offered it keeps its size at the
parked corner plus the usable-area inset. The answer
is the first observation with an attempted setter behind it, or the end of the
transaction without one. All answers remain at that usable top-left, including
clamped, rejected and later sizes. This deliberately differs from upstream's
centering of smaller clients: the title bar stays directly below the menu/notch
safe area without an added gap. The request uses the full display below that
safe area, without a Dock inset. An application may still grant less space;
its actual size is retained, so drawing and hit testing use the same rectangle.
The exit restores the exact place from before fullscreen.

## Leaving

Whatever ends it, the exit is upstream's `exit_fullscreen_on` and happens at
once: the window's top-left is back where it was saved, its pin is back, and
the output has its camera and zoom back with every animation aimed at the
parked view dropped. The native frame it had before is then owed to it and asked
back through a size transaction. The size and native global origin travel as
separate `requested` and `native_origin` fields; neither is derived from the
restored camera or the world top-left. Even an unchanged size needs a native
position write if its origin moved. The saved world top-left remains exact when
the application grants a different size. If something else has placed the
window in between, a drag or a nudge, it keeps that top-left (upstream
`drop_owed_recenter`); a placement that is itself a center, IPC `Move` and
`move-to-bookmark`, centers the restored size on its point instead (upstream
`map_window_to_rule_point`).

The restore obligation survives the setter's result until the transaction's
final read confirms its native origin. If the application relocates the window
between those reads, or the final read fails, the frame stays owed for a retry.
Each retry begins with a fresh read even when cached geometry matches; a matching
frame needs no setter. AX/CG agreement and origin tolerance are specified in
[the resize protocol](NATIVE_RESIZE.md#commands-and-effects). These observations
do not establish that an application will keep the frame after the final read.

What ends a fullscreen is upstream's list:

| | |
| --- | --- |
| `toggle-fullscreen` | as above |
| any action upstream does not run during fullscreen | ends the **active** output's first, then runs on the restored canvas. Upstream's list of those that do run: `toggle-fullscreen`, `spawn` (but not `exec`, `exec-terminal`, `exec-launcher`), `reload-config`, `switch-layout`, `toggle-cursor-pan`, `set-trackpad`, `send-to-output`. A refused action is rolled back with the exit |
| IPC `Camera` and `Zoom` writes | after the request is known to be sound; a read ends nothing |
| IPC `Suspend` | upstream runs it through its action |
| a bound pan or zoom (`pan`, `zoom`, `zoom_by`), which is what a bound drag and a bound wheel or trackpad scroll send | ends the fullscreen of the output it acts on |
| a wheel notch bound to an action | nothing of its own: the shell runs the action like a key's, and the action's guard decides (the second row) |
| a grab (`begin_drag`, `begin_resize`, `begin_native_resize`) | the same as a pan, then raises and focuses the window, then takes hold of it on the restored canvas: [the order of a grab](#the-order-of-a-grab) |
| a continuous trackpad gesture (a swipe bound to pan, move or resize, a pinch bound to zoom) | the same. A threshold or hold gesture fires through the action dispatch, whose guard decides |
| another window is activated on that output (`activate` with `native`) | first, so the target is not focused behind it and what is visible is judged by the restored camera. A new window that macOS made key as it opened is one such: [below](#a-new-window) |
| the fullscreen window closes or becomes a stand-in | the output has its view back before the focus is handed on; what stays of the window takes the frame it had before, pin included |
| the fullscreen window loses its source (a detach) | the same, but its slot keeps the size the window has, at the place from before: [Saving](#saving) |
| another window takes the output over (a rule's `fullscreen`, `send-to-output`) | the incumbent leaves first |
| the output is gone | once the shell has said which outputs exist: [below](#outputs) |

On a fullscreen output a trackpad gesture resolves its binding in the window
context wherever the pointer is, as upstream's does.

What does **not** end it, as upstream: a new window mapping that does not
take the native keyboard ([below](#a-new-window)), IPC `Focus`, IPC `Close`, a
hover, `spawn`, a press or a scroll the fullscreen window claims by its
`pass_mouse` (it is the application's:
[the pointer](#the-pointer-and-other-outputs)), IPC `Resize` of any window, and
anything on another output. IPC `Close` is upstream's
`cmd_close`, not its action: it asks the window to close, or dismisses a
stand-in, and nothing else. Asked of the fullscreen window itself, the
fullscreen ends when the window is gone, by the row above.

### The order of a grab

Upstream's press bound to a move or a resize on a fullscreen output
(`on_pointer_button`): its fullscreen block ends the fullscreen first, and the
binding's own arm then runs on the restored canvas, where it raises and
focuses the window and installs its grab. One order here, in one command:

1. the fullscreen of the output the press is on ends (`fullscreen_grab`). A
   window that is fullscreen on another output is not this press's to take:
   `a fullscreen window is not moved or resized by hand`;
2. the window is raised and focused, and the reply is that focus request
   (`{"effect":…}`; for `begin_native_resize`, whose `effect` is its
   transaction's, the one entry of `effects`);
3. the grab is installed. A screen-pinned window, pinned again by the exit,
   gets [the pinned drag](RULES.md#dragging-a-pinned-window).

A grab that is refused at any step rejects the whole command, so nothing
ended and nothing was focused for it. The move gesture is upstream's
`try_start_gesture_move` instead: the exit, the drag, then the raise and the
focus ([GESTURES.md](GESTURES.md#dispatch)). The window the command names is
the one `hit` reported, the fullscreen window; upstream tests the restored
canvas again under the pointer, which the exit has warped.

### The parked camera

Upstream refuses every camera and zoom write on a fullscreen output. Here no
flight is armed on one (`navigation` is `null`), cursor edge pan does not arm
there, and every command ends by putting the output back at its parked camera
and zoom 1 with nothing in motion. IPC `Focus` of another window therefore
focuses it behind the fullscreen window and moves nothing, as upstream's does.

### Sizing actions out of fullscreen

A sizing action is not one upstream runs during fullscreen, so it ends the
fullscreen and then acts on the restored window. Upstream takes its numbers
from the restore authority, not from the frame that still has the output's
size (`src/tests/fullscreen_handoff.rs`), and so does this: `fit-window`,
`fit-window-snapped`, `fill-window`, `grow-window` and `shrink-window` measure
a window still owed its size by that size, and their own request replaces the
owed one. One press, one transaction: from the output's size straight to the
fit, the fill, the unfit or the step. A step that moves a left or top edge
holds the opposite edge of the restored frame, whatever size is granted, as a
step on a window that was never fullscreen does: the transaction's own edge
anchoring would measure from the frame that still has the output's size, so
for this one step the plan places the window and the transaction moves no
edge.

### `home-toggle`

Upstream's arm. Pressed out of fullscreen and away from home, the restored
view becomes the return, the window is remembered, and the output snaps home
at zoom 1 with no flight. Pressed at home with that window still open, the
view is put back in one step and the window is fullscreen again.

### `send-to-output`

Runs during fullscreen: the focused fullscreen window becomes fullscreen on
the output adjacent to its own, which gives the output it leaves its view
back. One transaction, from one output's size to the other's. With no adjacent
output nothing happens.

## A size that is owed

There is one size transaction ([SIZES.md](SIZES.md#a-second-action-while-a-size-is-owed)).

- **Entering** while another window's transaction is unresolved is refused
  like any sizing action: `a native resize of window N is still pending`.
  During a drag or resize gesture: `a window is under an interactive move or
  resize`. Nothing else refuses an enter. A window the adapter will not
  resize answers `unsupported` for that request. Each later enter asks again,
  then aligns the size it has or observes that it is settable by now
  ([NATIVE_RESIZE.md](NATIVE_RESIZE.md#readback-mode)).
- **An exit is never refused.** It is a consequence of something that
  happened. Its size is *owed*, and delivered as soon as it can be.
- **An exit while the enter is pending** takes that transaction over: the
  restore size replaces the output's in the transaction's one latest-request
  slot, so the window is never left at the output's size. Before anything was
  sent, the enter's baseline still supplies the original native frame and the
  request is walked back without a setter; with the
  setter already sent, the same transaction asks for the old size next. The
  reply has no `effect` then: nothing new is dispatched. The answer to a
  setter that asked for the other size is none to the request now in force:
  the window is neither placed for it nor counted as having its size until
  that request's own setter has answered. An enter pressed while the exit is
  pending takes it over the same way, at any point of it, and still comes
  back to the size and the place from before the first.
- **An exit whose frame is not confirmed** leaves the frame owed: cancelled
  before its setter (Escape, a screen change that
  removes the transaction's output, a detach elsewhere), a read that failed,
  an adapter that was not available, or a final read that found the wrong
  origin. The next reply that can carry it begins another transaction, three
  in all at most for one exit. A cancelled fullscreen transaction drains its
  sent work and carries the restore's first effect as soon as its slot is free.
  Repeated failure ends at that limit; the canvas uses the size actually observed.
- **A window that was asked to close** (it carries a close mark:
  `close-window`, `suspend-window`, IPC `Close` and `Suspend`) keeps the
  frame it is owed until it is gone or the mark lapses. `suspend-window` on
  a fullscreen window sends the restore and the close in one reply; when the
  window goes before its old size was observed, the transaction ends
  unanswered and the stand-in is seated at the frame from before all the
  same, as upstream's suspend mark carries that rectangle.
- **An exit while another transaction holds the slot**, or one made by a
  command whose reply the shell does not perform sizes from, leaves the size
  owed. It leaves with the first reply that can carry it.

The replies that can are the ones the shell passes to its size hook
(`-consumeSize:`, the first step of `-applyReply:`): `action`, `hot_corner`,
`tap`, `ipc`, `gesture_begin`, `gesture_update`, `gesture_end`, `activate`,
`clear_focus`, `pick` and `pointer_nearest`. A reply that lists `effects`
carries the transaction under `transaction` and `effect`. One whose `effect`
is its focus request (`activate`, `pick`), or that has neither key
(`clear_focus`), gains `transaction` and an `effects` list holding that focus
request, if any, and the transaction's effect: with an `effects` list present
the shell reads the size effect and the focus request from it. A reply that
already carries a transaction is left alone. Until it is delivered the window
sits where the exit put it, at the size it still has, and a save writes it so.

`hover` is not one of them. The shell reads a hover reply's `forward`, `dirty`
and focus request and nothing else (`native/desktop/pointer-hover.m`), so a
transaction begun there would never be performed, and the next action would
cancel it with the size still undelivered. A pointer motion therefore begins
nothing; the click, key, gesture or IPC request that follows does.

Nor is the reply to a `native_resize_result`. The one transaction it can
begin is that of the next window still owed its rule's `size`
([RULES.md](RULES.md#a-rules-size)), which the freed slot goes to first; a
size an exit owes then finds the slot taken and leaves with a later reply.

An output that comes back at another size owes its fullscreen window that new
size the same way (upstream's `resize_fullscreen_for_output`).

## A new window

Upstream never lands a new window on a fullscreen one. With the focused
window fullscreen, else the active output's, a new window that no rule
positions is placed in the background: beside the frame the fullscreen window
comes back to, a `snap.gap` away, by upstream's own `place_auto` among the
canvas windows, biased toward that frame's center; with no slot, just below
it. Nothing cascades it. The attach asks for no focus and moves no camera, and
the window is drawn on the fullscreen output not at all.

Whether the fullscreen then stands depends on the native keyboard, which is
macOS's to give. A window that opens without it, its application not being
frontmost, stays in the background and the fullscreen stands, as upstream's
does. A window that macOS makes key as it opens, the usual case for a window
the user has just asked for, is reported by the shell's focus follow like any
native activation (`activate` with `native`; by reading the shell, at the
first poll after a managed run has bound a window it discovered, the polls
being 80 ms apart, at the next focus poll for a window bound from the
chooser of a `--manual` run, half a second away at most (such a run has no
window manager and so no observers to make it a second), and only with
Accessibility access). That ends the fullscreen
as any activation on that output does: the new window is focused beside the
restored frame, and flown to if it is clipped. `spawn` itself ends nothing,
but the window it opens can. Upstream never activates a window it placed in
the background: see [Differences from upstream](#differences-from-upstream).

A rule's `fullscreen = true` is applied once the window is placed, in place of
the arrival's navigation: the window enters on the rule's `output`, else its
pin's, else the active one, displacing whoever is fullscreen there. Entering
raises and focuses it whatever `focus_on_open` says, as upstream's does. It
logs its `open` like any new window ([EFFECTS.md](EFFECTS.md#lifecycle-events)).
`rule.not_applied` keeps `fullscreen` when it could not be applied:
without the capability, for a window that took over a slot, during the launch
pass, or when the enter cannot begin now (another transaction holds the slot,
a gesture is in progress); the window is then placed, focused and asked for
its rule's `size` like any other.

A rule that names a `size` too follows upstream's order at the map
(`src/handlers/compositor.rs`): the first commit configures the size, the
next places the window for it, and the deferred fullscreen then saves that
frame. Here the window is placed for the size its rule names
([RULES.md](RULES.md#a-rules-size)), a rule-pinned one at its pin, and enters
from there at the size it has, the only one a native observation committed.
The frame it was placed for is where it comes back to, at the rule's size,
which is owed like any exit's and asked only then: one transaction takes the
window from its own size to the output's, and it waits in no queue. A frame
that could not be placed for the size asked is placed for the window's own,
and then comes back at that. `rule.not_applied` names neither field.

There is one size transaction, so fullscreen and the queue of rule sizes wait
for each other like any two requests. A ruled window that maps while an enter
or an exit holds the slot is placed, stands at its own size and is asked in
the reply to the result that ends that transaction; an enter that finds the
slot taken is refused, or for a rule's `fullscreen` not applied. A new window
that is tucked in the background is placed against the frame each waiting
window is becoming, not the one it stands at, as every placement is.

## The pointer, and other outputs

- `hit`, `input` and `hover` on a fullscreen output reach its fullscreen
  window where it is drawn and nothing else: not a widget, not a pinned
  window, and nothing in the band a smaller window leaves.
- A fullscreen window is on its own output only. No other output places it or
  hits it, whatever canvas its camera shows, and while its output is removed
  it is drawn nowhere.
- A fullscreen output shows a screen-space window, not a canvas viewport, so
  it projects no viewport outline onto the other outputs, opaque or
  translucent (upstream `build_output_outline_elements`). The outlines are
  the shell's: its renderer leaves out a neighbour whose
  `outputs[].fullscreen` is set.
- `focus_follows_mouse`: on a fullscreen output the window owns the focus and
  is given it back wherever the pointer is, the band included, instead of a
  hover target being looked for (upstream `maybe_hover_focus`).
- It is no canvas window (upstream `is_canvas_window`): no navigation target,
  no snap rectangle, no member of a cluster, not framed by `zoom-to-fit`, no
  obstacle to placement, no pick target, and IPC `Move` and `Resize` writes
  answer upstream's `…it is pinned, fullscreen, …`. It stays in the focus
  history, and `cycle-windows` passes over it as upstream's `cycle_step` does.
- Navigating to it (`navigate_window`, IPC `Focus`) focuses it on its own
  output and does nothing at all from any other.
- `hot_corner` on an output that is fullscreen, with `disable_when_fullscreen`
  in force there (upstream's default), runs nothing and answers
  `{"navigation":null,"effects":[],"dirty":false}`. With it `false` the action
  runs. Another output's fullscreen suppresses nothing.
- `pass_mouse`: the fullscreen window claims the bindings its live rule
  lists, for a press, a wheel or trackpad scroll and a wheel notch, with no
  pick-mode gate (upstream `fullscreen_claims`). `mouse_binding` then answers
  `{"binding":null,"passed":true}`, the shell forwards the event to the
  application, and nothing ends ([RULES.md](RULES.md#pass_mouse)).
- `pass_keys`: `snapshot.pass_keys` is the fullscreen window's while it holds
  the keyboard, as any window's. Entering asks for the focus, and the list
  follows once that request is answered ([RULES.md](RULES.md#pass_keys)).
- A screen-pinned window is not drawn on a fullscreen output and is no target
  there. A pinned drag in progress is frozen while the pointer is over one,
  and no output becomes fullscreen under a drag
  ([RULES.md](RULES.md#dragging-a-pinned-window)).

## Outputs

Upstream ends a fullscreen when its output goes. The shell removes every
output on any screen change and registers the present ones again, so only
`outputs_settled` (and the end of a discovery pass) knows which are really
gone, as for a pin ([RULES.md](RULES.md#wire-contract)):

- `remove_output` keeps the fullscreen. Until the output is registered again
  the window is drawn nowhere and IPC `State` lists no fullscreen for it;
- an output registered again keeps it, parked as it was; at another size its
  window is asked for the new one and meanwhile aligned to its usable top-left;
- `outputs_settled` ends the fullscreen of an output that is not connected:
  the window is back on the canvas, and the output's saved camera is the one
  from before, for when it returns. `dirty` is true.
- `outputs_settled` also moves a pin that a fullscreen put away when the
  pin's own output is gone while the fullscreen stands on another (a pinned
  window sent over by `send-to-output`): to the first connected output,
  clamped for the size the window comes back to, as upstream's
  `reassign_orphaned_pinned` rebinds it. `dirty` is true. Without that the
  exit would pin the window to an output that is gone.
- `outputs_settled` with no output registered at all says every display is
  gone: every fullscreen ends, and no pin moves, there being nowhere to move
  it. The desktop stays up while its displays are away and the shell sends
  the command then too, so wherever macOS reports no display for a moment (a
  sleep, a cable) a fullscreen window is back on the canvas afterwards. This
  is read from `fullscreen_outputs_settled` and `rehome_pins`, and from the
  shell's `-openPanels`; no scenario registers no output, and none was run.

## Saving

Upstream's session store never saves a fullscreen, and neither does a `save`:
all of this state is ephemeral and gone after a `load`. The output's camera is
saved as it stands, parked, as upstream's `per_output_cameras` writes it.

Upstream saves a fullscreen window at the frame it had before
(`live_window_rect`), because its client ends with the compositor and maps
again at the saved size. A Mac application outlives the canvas, and its window
keeps the size it has. So a fullscreen window is saved at the **place** it had
before, with the pin it had, and at the **size it has**: the only size a
native observation committed, and the one the next size transaction's first
read is measured against. A window still owed its size is saved as it stands,
where its exit put it. A fullscreen window that loses its source (a detach,
as a failed capture stream is answered with) leaves its slot the same way. A
slot written with the old size instead would be adopted by a window of the
output's size, and every later size transaction on it would fail its first
read with `baseline size differs from committed logical size`.

So that this is the exception, the shell ends every fullscreen before it
saves and detaches at Quit (a `quit` binding, `msg action quit`, SIGTERM or a
log out: how a normal run's canvas closes), and performs the size
transactions to their end first, bounded at three seconds
([shell notes](../../native/desktop/README.md#limits-of-fullscreen)); the
`quit` action's own guard ends the active output's, as upstream's does. The
scene saved then has the restored cameras and the frames from before. What
this section describes is what is saved when that is cut off: a crash or a
kill, an application that does not answer in time, a size that was clamped.
The window then comes back as a canvas window of the size it was left at, at
its old place, and its size from before the fullscreen is not restored.

## Differences from upstream

- **No transition.** Upstream keeps the scene behind visible while the entry
  animation grows, and holds the picture during the exit. Here the output
  shows the fullscreen window alone from the action, at the size it has until
  the native size arrives, and the exit is immediate.
- **The answer is a native result.** Upstream's client acks a configure; here
  the answer is the transaction's first observation behind an attempted
  setter. A window whose transaction fails, or that the adapter will not
  resize, stays fullscreen at its own size, aligned to the usable top-left,
  at every enter. A failed enter is not asked again; an exit
  whose native frame is not confirmed is, three transactions at most
  ([above](#a-size-that-is-owed)). Upstream's configure cannot fail.
- **Background arrival focus is corrected once.** The attach reports its
  background placement. With the existing native input observer enabled, the
  shell briefly pins that new root and the current Fill binding. Its initial
  native activation requests the Fill root's focus once, without moving the
  camera or changing either world frame. The ticket expires after 1.5 seconds;
  physical key/down/scroll, explicit navigation, binding/Fill changes, or a
  different native focus retire it. A fresh worker read must still name the
  arriving root: a sheet or dialog never authorizes that correction. Without
  the cancellation observer, native activation follows the ordinary policy.
  Later deliberate native activation exits Fill and carries native restoration.
  Focus alone intentionally leaves Fill active, as described under the parked
  camera. The geometry result of a run in the macOS 27.0.1 UTM guest does not
  establish that.
- **A saved fullscreen window keeps the size it has**, at the place from
  before, where upstream saves the frame from before: [Saving](#saving).
- **What is hit is what is drawn.** Upstream's canvas walk on a fullscreen
  output still reaches a culled window that lies under the band beside a
  smaller fullscreen window, or one raised above it since. Here only the
  fullscreen window answers there.
- **`mouse_binding` names no output**, so a press in the band beside a smaller
  fullscreen window resolves its binding in the canvas context the shell
  reports; upstream resolves every press on a fullscreen output in the window
  context. A trackpad gesture does take the window context.
- **A window that is no longer fullscreen is at the output's size for a
  moment**, where upstream's stage believes the restored size at once: world
  sizes are only ever committed by a native observation. Sizing actions, IPC
  `Move` and `move-to-bookmark` use the owed size; anything else reads the
  frame: IPC `Resize` and `Move` reads, `State`, visibility tests.
- **An exit by a command whose reply carries no transaction** (`pan`, `zoom`,
  `zoom_by`, `begin_drag`, `outputs_settled`, a displaced incumbent) leaves
  the size owed until the next reply that can carry it: the next action, IPC
  request, trackpad gesture, click on a window, click on empty canvas or
  pick. Moving the pointer is not enough. Until then the window is back on
  the canvas at the output's size.
- **A resize drag out of fullscreen starts from the output's size.**
  `begin_resize` and `begin_native_resize` end the fullscreen and then drop
  the size the exit owed, as a resize drag drops a fit's restore point: the
  drag takes hold of a window that still has the output's size. Upstream's
  stage has the restored size by then.
- **One transaction.** A rule's `fullscreen` that finds the slot taken is not
  applied, where upstream queues nothing either but has no slot to find taken.
- **Output removal** is settled at `outputs_settled`, not at `remove_output`.
- **The launch pass** applies no rule's `fullscreen`: those windows were
  already open, and nobody opened them here. Upstream has no such pass.
- **No client asks.** A native window's own fullscreen request, upstream's
  `fullscreen_request` and the idempotent re-assertion, does not exist: macOS
  native fullscreen moves a window to another Space and is not this.
- **No pointer warp and no pointer constraint.** The pointer is the system's,
  in screen space; upstream's warps on enter and exit and its carrying of a
  locked cursor have nothing to do here.
- **`focus-cycle` commands** (`cycle_focus`, the older command beside
  `cycle-windows`) do not pass over a fullscreen window.
- A screen-pinned window's size is handed back by a size transaction although
  it is pinned again by then: one of the two requests that size a pinned
  window, the other being its rule's `size` as it maps
  ([SIZES.md](SIZES.md#differences-from-upstream)).
- **A rule's `size` beside its `fullscreen` is owed, not asked first.**
  Upstream configures the client to the rule's size and then to the
  output's. Here the first of those is never sent: the window goes from the
  size it has to the output's, and the rule's size is the one its exit asks.
- **In the band beside a smaller fullscreen window nobody claims.** Upstream
  asks the fullscreen window's `pass_mouse` for a press, a scroll or a notch
  anywhere on its output. Here the claim is asked of the window `hit`
  reports, and `hit` reports none there.
- **What the shell draws on a fullscreen output** beside the window is the
  error bar and nothing else: no closing snapshot, no stand-in fade, and a
  window that opens fullscreen is not held back for its size
  ([shell notes](../../native/desktop/README.md#what-a-fullscreen-display-shows)).

## Verification boundary

`tests/fullscreen_flow.rs` crosses the exported C ABI and JSON decoder on two
outputs, neither at the global origin and of different sizes, one of them
zoomed out at a fractional camera. The test plays the shell's part: it answers
every resize effect with a synthetic `native_resize_result`. Its scenarios
cover the gate (against literals captured from the tree before this
work), enter and exit by toggle, centring, each way out, the parked camera, a
new window and a rule's `fullscreen` and `output`, the translucent rule, hot
corners, fit and fill and the sizing actions out of fullscreen (a step on
each edge among them), a widget, a stand-in and a pinned window (and the pin
whose output goes meanwhile), the one transaction slot (an exit and an enter
at each point of the other's transaction, a cancelled, unanswered and
repeatedly failing restore, a window the adapter will not resize), IPC
`Close`, a new window that takes the keyboard, the pointer, Alt-Tab,
`home-toggle` as an action and as the direct command, `send-to-output`, and
save, load and the adoption that follows; and, since the merge with effects,
pass-through and the polish pass, a fullscreen window's `pass_mouse` claims and `pass_keys`, the order of a
grab, the pinned drag beside a fullscreen output, the frost and the open and
close events, and a ruled size that waits out an enter.

Native-frame restoration scenarios also cover independent native/world origins,
fractional baseline sizes, stale source dimensions, an exit before the enter's
baseline arrives, origin-only restoration, cancelled setters, rejected origin
writes, relocation between setter and final read, and a failed final read followed
by fresh confirmation. These remain C ABI/controller evidence with synthetic
native results.

It establishes the controller's policy and wire behaviour. It does **not**
establish that:

- a resize effect resizes a native window, or that a real window reports the
  size the test said it took;
- the shell routes any of these replies to its resize coordinator. The keys
  are the ones `-applyReply:` and `-consumeSize:` read, by reading
  `native/desktop/main.m` and `navigation-coordinator.m`; the `effects` list a
  focus-shaped reply gains was read there and never run;
- the compositor draws a `fullscreen` placement over a black or canvas
  backdrop, leaves out the outline of a fullscreen neighbour, or draws
  anything;
- input forwarded to a fullscreen window lands where it is drawn;
- the shell ends a fullscreen at Quit. Its
  `-endFullscreens` sends commands this test covers one by one (a
  `toggle-fullscreen` on a fullscreen output, an `ipc` `State` that carries
  an owed size), but the method itself is compiled and has run in the app
  only with nothing fullscreen;
- a new window is key when it is attached, or that the shell's focus follow
  reports it. The scenario sends that `activate` itself.

Upstream's tests were read for the contract and are not executed here. Its
scenarios that need a Wayland surface are not ported: the unacknowledged
commit as distinct from an acknowledged one of the same size, the carrying of
a locked or confined cursor, the frozen exit picture, the animated
background's render eligibility, and the coasting camera of
`fullscreen_exit_cost.rs` (no pan can coast on a fullscreen output here: it
ends the fullscreen first).
