# Window rules, widgets and screen-pinned windows, ABI 1

DriftWM's per-window policy: `[[window_rules]]` matched when a window maps,
widgets fixed to the canvas, windows pinned to an output's screen, and the
bindings a window's rule takes from the canvas (`pass_keys`, `pass_mouse`).
The shell sends `outputs_settled` once it has registered its displays.

The rules are adapted from <https://github.com/malbiruk/driftwm> at
`352333a8fa1b22171492d4b71a54102045c9a19d` (GPL-3.0-or-later):
`src/handlers/compositor.rs` (a new toplevel's first sized commit),
`src/state/pinned.rs`, `src/state/mod.rs` (`is_canvas_window`),
`src/state/output.rs` (`output_for_window`), `src/state/persistence.rs`
(`screen_space_inventory`), `src/input/actions.rs` (`toggle_pin_to_screen`,
`MoveToBookmark`), `src/input/pointer.rs` (the move and resize bindings pass
over a widget, and raise and focus any other window ahead of their grab; of
`try_pinned_button`, that focus and the screen-space drag of a pinned window
are adapted and its resize is not) and `src/ipc/mod.rs` (`cmd_pin`,
`cmd_opacity`, the refusals of `cmd_move`, `cmd_resize`, `cmd_focus` and
`cmd_suspend`), and, for what the navigation actions, gestures and output
actions do with a widget or a pinned window, `src/input/actions.rs`
(`CenterWindow`, `CenterNearest`, `SendToOutput`), `src/input/mod.rs`
(`topmost_under`, `draggable_element_under`), `src/input/gestures/swipe.rs`
(`gesture_target_under`), `src/state/navigation.rs` (`navigate_to_window_on`)
and `src/state/pinned.rs` (`send_pinned_to_output`). The matcher, the merge and the opacity rule are not adapted:
they are driftwm-core's `Config::resolve_window_rules`, `AppliedWindowRule`
and `effective_opacity`, upstream's own code. The code is in
[`src/rules.rs`](../../../crates/desktop/src/rules.rs); the user contract is upstream's
[`docs/window-rules.md`](https://github.com/malbiruk/driftwm/blob/df3de27b26c7998e8a460cffd8a4925cbed3a322/docs/window-rules.md).

The pass rules and the drag of a pinned window are in
[`src/passthrough.rs`](../../../crates/desktop/src/passthrough.rs), adapted from the same commit:
`src/input/keyboard.rs` (the `pass_keys` test of a key press),
`src/state/window_lifecycle.rs` (`live_rule_for`), `src/input/pointer.rs`
(`pass_mouse_claims`, `pass_mouse_target_under`, `target_claims`,
`pass_mouse_claims_notch` and the three sites that call them, each with its
pick-mode gate, `start_pinned_move`), `src/input/gestures/swipe.rs` (the
pinned arm of `try_start_gesture_move`) and `src/grabs/move_grab.rs`
(`MoveGrab::new_pinned`, `apply_pinned_move`, its release and unset). The
lists, their merge and `PassList::allows` are driftwm-core's. A rule's
`layer_order` is read and [changes nothing](#layer_order), as upstream's does
for a window.

## Matching

A rule's `app_id` is matched against the window's **bundle identifier**, its
`title` against the source title, each as upstream matches them: an exact
string, a `*` glob, or a `/regex/`, case-sensitive. A rule with both needs
both. **Every** matching rule applies, in config order: scalar fields are the
last rule's, `widget`, `pinned_to_screen`, `blur` and `preserve_aspect_ratio`
are sticky once any rule sets them.

Rules are resolved **once, when a window maps**, that is at `attach`, and kept
with the window until it is gone:

- `retitle` re-checks nothing, as upstream documents: a widget stays a widget
  under a title no rule matches, and a window retitled into a rule is not made
  one.
- `load_config` changes no window that is already mapped. Only windows that
  map afterwards see the new rules. A pin survives a reload too: it is the
  window's state, not the rule's.
- What upstream resolves live stays live: `suspend_on_close` is asked with the
  title of the moment when the window closes, `restore_windows` at each
  `adoption_complete`. See [LIFECYCLE.md](LIFECYCLE.md).
- `pass_keys` and `pass_mouse` are live too, as upstream's `live_rule_for`
  makes them: each is asked against the config and the title of the moment,
  so a reload and a retitle take effect at once, on a window that mapped
  before the rule existed too. The window's `rule` in the snapshot still
  lists the merge it mapped with. See [Pass rules](#pass-rules).

## A new window

For an `attach` with neither `logical_id` nor `world_rect`, in upstream's order:

1. **Adoption** comes first, as before. A window that takes over a slot keeps
   the slot's frame, stacking and pin whatever its rule says of `position`,
   `pinned_to_screen` or `size`; it still gets the rest of its rule (`widget`,
   `opacity`, `decoration`, `blur`, `focus_on_open`).
2. **`pinned_to_screen`**, when there is an output to pin to: the rule's
   `output` by stable id if it is connected, else the active output of the
   `attach`. `position` is the frame's center measured from the **output's
   center**, Y up; without one the frame is centered. The frame is clamped
   until all of it is on the output; one too large for it starts at the
   output's top-left. With no output at all the window is not pinned and
   falls through to the next step.
3. **`position`**: the frame's center on the canvas, Y up, with upstream's
   integer halving. `position = [100, 50]` puts a 401 x 301 frame's top-left at
   world (100 - 200, -50 - 150). Nothing cascades off a ruled position.
4. Otherwise `window_placement`, as [LIFECYCLE.md](LIFECYCLE.md#2-placement).

The frame steps 2 to 4 place is the window's own, or, when its rule names a
`size` that will be asked, the frame of that size
([below](#a-rules-size)).

Then, once mapped:

- A **widget** and a window whose rule says `focus_on_open = false` are neither
  focused nor navigated to.
- A window **pinned** by its rule is raised and focused where it is; there is
  no canvas position to navigate to, so `navigation` is null.
- Any other placed window is focused and navigated to as before. A ruled
  position is not a cursor placement: it navigates.
- During the launch pass nothing is focused or revealed, as before.

For an explicit `focus_on_open = false` rule after startup, `attach` also
returns `focus_on_open_suppressed: true`. With its existing physical-input
observer installed, the macOS shell can correct the new root's initial native
activation once within 1.5 seconds, preserving the exact previously confirmed
live focus. Input, a dialog, a changed binding, or expiry cancels that correction;
later deliberate selection works normally. A widget alone does not grant this
correction, nor does startup adoption. A nil or stand-in prior focus cannot be
restored through the native focus driver and receives no correction. This is
bounded arrival handling, not a permanent prohibition on activating the app.

An `attach` that names its `logical_id` or its `world_rect` has decided the
frame itself: the window gets its rule less the placement (no `position`, no
pin, no `size`).

### A rule's `size`

A rule's `size` is a native size, and reaches a window only through the
[size transaction](SIZES.md#what-a-sizing-action-does), which a shell performs
once it has sent `native_resize_capability` ([SIZES.md](SIZES.md#the-gate)).
So it follows that gate:

- **Without `native_resize_capability`** nothing is asked. The window keeps
  its own size, a `position` centers that size, and `rule.not_applied` names
  `size`. This is the contract of a caller that has not sent the capability
  (only the C-ABI tests do; the shell always sends it).
- **With it**, upstream's order holds. Upstream configures the rule's size at
  the window's first commit and places the window on the commit after it,
  for the size it then has (`src/handlers/compositor.rs`): step 2, 3 or 4
  above takes the frame of the size the rule names, for a widget and a
  window the rule pins like any other. So does this. A `position` is that
  frame's center with upstream's integer halving, a pin is that frame's,
  clamped onto its output, `window_placement` places that frame, and the
  arrival's flight is aimed at it. `position = [0, 0]` with `size = [800,
  600]` puts the top-left at world (-400, -300), whatever size the window
  had. The cascade and the `auto` placement of a later arrival read the
  frame a ruled window is becoming, for one that has been asked and for one
  still waiting its turn alike, so several windows of one rule that map
  together cascade as upstream's do, where its stage already holds each at
  its ruled size (`cascade_position`, `src/state/placement.rs`).

  Only a native observation commits a size, so until the window answers it
  has its own, standing centered in the frame asked for: a 401 x 301 window
  at (-400 + 399 / 2, -300 + 299 / 2) = (-201, -151). A pinned window
  stands at its pin. The size is asked through
  `Controller::request_window_size`, IPC `resize`'s own path, which keeps
  the center, and upstream's halving toward zero then lands the frame on the
  top-left computed for it, to the pixel. The `attach` reply carries
  `transaction`, and the transaction's effect as the one entry of `effects`,
  for the shell's resize coordinator; `effect` stays the arrival's focus
  request. `rule.not_applied` no longer names `size`. The window's `open` is
  logged with the map, once, whatever becomes of the size; a shell that
  animates it waits for the transaction
  ([EFFECTS.md](EFFECTS.md#beside-a-size-that-is-owed)).

**One at a time, in map order.** There is one size transaction
([SIZES.md](SIZES.md#a-second-action-while-a-size-is-owed)). A ruled window
that maps while another transaction, a drag or a resize is unresolved, the
launch pass included, is placed for the size asked like any other and waits:
its `attach` reply carries no transaction, and `rule.not_applied` names
`size` until its turn. It is asked

- in the `native_resize_result` reply that ends the transaction in the slot,
  whoever began that one, unless a drag or a resize gesture is on at that
  moment: the reply's `transaction` and `effect` are then the waiting
  window's, the keys under which a transaction's own next effect comes back,
  and the shell's resize coordinator performs it like any other;
- or in the `attach` reply of the next new window that maps, ruled or not,
  under `transaction` and `effects`, if nothing is in the way by then. A
  window that waited out a drag is asked there, or when a later transaction
  ends, because nothing ends a gesture in a reply the shell hands to its
  coordinator.

The oldest is asked first. A window that closes or loses its source before
its turn leaves the queue, and so does every window when the shell says it
can no longer deliver a size; a window that cannot be
asked when its turn comes (its application does not accept a size, or the
frame would leave the integer range) leaves it too, with `size` still named,
and the next is tried in the same reply.

A window **the user sizes before its turn** leaves the queue as well, with
`size` still named: by IPC `resize`, whatever size it names, the one the
window has included, by a step, a fit, a fill or a resize drag. Upstream's
rule size is one-shot at the window's first commit (`pending_size`,
`src/handlers/compositor.rs`: "so the user can still resize"), and nothing
forces it over a size given since. Sizing another window ends no wait.

A queued window is not the transaction's: it can be moved, dragged by a
move, pinned and closed meanwhile, and its request then keeps the center of
wherever it stands, or the pin it has.

Still not asked, with the capability on, and still named in `not_applied`:

- a window that **takes over a slot**, which keeps the slot's frame as
  upstream's adopted window does;
- a window the user sized while it waited its turn (above).

A window that maps with the rule's size already is asked nothing, a widget
and a pinned window included, and `size` is not listed. The request never
fails the `attach`: a frame that cannot be placed for the size asked is
placed for the window's own, as without the capability.
`preserve_aspect_ratio` does not bend it: upstream locks the ratio for
interactive resizes only.

`fullscreen` is applied under the same capability, in upstream's order for a
rule that names both: the size is configured first, the window placed for it,
and the deferred fullscreen then saves that frame. So the window is placed
for the size its rule names, a rule-pinned one at its pin, and enters
fullscreen from there in place of the arrival's navigation and of this
request. It enters at the size it has: the rule's `size` is never asked
before the output's, and is owed as the size the window comes back to, at
the frame it was placed for. It waits in no queue, and `size` is not listed:
[FULLSCREEN.md](FULLSCREEN.md#a-new-window). A fullscreen's own transaction
holds the one slot like any other, so a ruled window that maps meanwhile
waits its turn behind it and is asked in the reply that ends it; and a
`toggle-fullscreen` on a window that still waits is a sizing of the user's
that takes it off the queue: it comes back at the size it had, and `size`
stays listed, since it was never asked.

While its size is owed a window is the transaction's, a rule-pinned one and
a widget like any other: `window_closed` waits for the result, no drag takes
it (`a native resize of window N is still pending`), its pin waits
(`resize must drain before structural change; …`), and
[`hover`](POINTER.md#what-holds-the-pointer) forwards no motion.

## Widgets

A widget is fixed to the canvas:

- **Below every window.** After every command each non-widget window is raised
  above the widgets in its current order, which is upstream's
  `enforce_stacking`: `snapshot.windows` lists widgets first.
- **Not moved or resized by hand.** `begin_drag`, `begin_resize` and
  `begin_native_resize` refuse it (`a widget is not moved or resized by
  hand`). `nudge-window`, `move-to-bookmark`, `close-window` and
  `suspend-window` do nothing with a widget focused, without an error, and so
  do the [sizing actions](SIZES.md#widgets-screen-pinned-windows-and-rules).
- **IPC `Move` alone repositions it**, by id. The move lasts for the session.
- **Out of cycling.** It can hold the focus, and a click still requests native
  focus, but it never enters the [focus history](FOCUS.md), whoever answers
  that request, and a cycle step taken from it goes to the head of the
  history. IPC `Focus` refuses it; an app-id selector
  passes over it, an id reaches it. No close hands it the focus: when the
  last canvas window in view closes, nothing is focused.
- **Out of snapping, clusters, zoom-to-fit, the dynamic minimum zoom and auto
  placement**: it attracts no dragged edge, joins no group move, and neither
  anchors nor obstructs a new window. When a focused widget closes no window
  is its spatial neighbour: the focus goes to the most recent canvas window
  in view, and no camera moves
  ([LIFECYCLE.md](LIFECYCLE.md#a-window-closes)).
- **A slot that becomes a widget drops its drag.** A detached slot can be
  dragged; if its window returns under a title a `widget` rule matches while
  the drag is on, the drag ends there.
- **Never a stand-in.** `suspend_on_close` and `restore_windows` do not apply,
  IPC `Suspend` answers `widgets cannot be suspended`.
- Drawn opaque unless its rule or an IPC write gives it an opacity.
- **In a canvas screenshot** it is drawn below the other windows, and `all`
  does not frame it ([RENDER.md](RENDER.md#screenshots)).

## Screen-pinned windows

A pinned window is fixed to one output's screen space: a top-left in whole
output-local points and its own size, whatever the camera and the zoom. It is
drawn above every canvas window of that output and on no other output.

- **`toggle-pin-to-screen`** acts on the focused live window. Pinning takes the
  output showing the window's center, else the active output, and the point
  its top-left shows there right now. Unpinning puts the frame back on the
  canvas at the point the pin shows under the current camera and zoom, raised.
  The **top-left never moves on screen** in either direction; the size does
  when the zoom is not 1, because a pinned window is drawn at its own size.
  With no output to pin to, and with a stand-in focused, nothing happens.
- **Out of the focus history** while pinned; it keeps the focus it had.
  Unpinning the focused window puts it back at the head when its focus was
  settled: confirmed or observed natively, or answered `focus_logical`. No
  close hands it the focus, as for a widget.
- **Dragged in screen space**, by the move binding and by the move gesture
  ([below](#dragging-a-pinned-window)). Native edge and gesture resizing also
  uses screen space, with no snapping or cluster. Logical `begin_resize`
  remains a canvas operation. `nudge-window`, `move-to-bookmark` and the
  [sizing actions](SIZES.md#widgets-screen-pinned-windows-and-rules) pass it
  over, IPC `Move` and `Resize` refuse to write it. Reading still works.
- **Out of snapping, clusters, zoom-to-fit and auto placement**, like a widget,
  and like a widget it has no spatial neighbour when it closes. Neither is an
  obstacle to `fill-window`, shoved by `fit-window-snapped` or framed by
  `zoom-to-fit-snapped`.
- `navigate_window` and IPC `Focus` raise and focus it without a navigation.
- **Out of canvas screenshots**, as upstream documents: `msg screenshot` of
  the view, of `all` or of a region never shows it, and `screenshot window`
  captures it alone at the canvas frame its pin shows
  ([RENDER.md](RENDER.md#screenshots)).
- Its canvas frame is bookkeeping, re-anchored after every command to the
  point the pin shows (upstream's `sync_pinned_locs`), so an unpin, a stand-in
  and a save all take the frame that is on screen.
- **A pin waits** for a drag, a resize or a native resize transaction to end,
  the drag of the pinned window itself included: `toggle-pin-to-screen`, IPC
  `Pin` and `send-to-output` are refused while it is held.
- **A stand-in is never pinned**: a pinned window that leaves a stand-in is
  back on the canvas where its pin showed it.
- **Outputs.** `remove_output` moves no pin: the pin stays bound to its
  output and is drawn nowhere (`screen_rect` null, absent from
  `State.pinned`). An output that registers again at the size it had gets its
  pins back exactly where they were, a frame hanging off its edge included.
  One that registers at another size, or for the first time in a run, has its
  pins moved inward until each whole frame is on it. `outputs_settled`, which
  the shell sends once it has registered every display there is, moves each
  pin whose output is still missing to the first connected output, keeping
  its place as far as the whole frame fits (upstream's
  `reassign_orphaned_pinned`); with no output connected it does nothing, and
  the pin waits for the next settle. A pin that has moved does not go back
  when its old output returns.

A pinned widget is drawn with the pinned windows and refused as a widget.

## Navigation, activation, gestures and outputs

Upstream's test for all of these is `is_canvas_window`: neither a widget nor
screen-pinned. Here it is `Controller::on_canvas`, and every path that picks,
flies to, grabs or sends "a window" asks it.

| Path | A widget | A screen-pinned window |
| --- | --- | --- |
| `center-window` | focused: the canvas window nearest the viewport center is taken, as with nothing focused; never the nearest itself | the same |
| `center-nearest` | no candidate; a focused one still anchors the search, as upstream's | no candidate, and a focused one does not anchor: the search starts at the viewport center |
| `focus-center` | not taken: with only a widget under the pointer nothing happens | passed over, as upstream's walk skips it: the canvas window beneath is taken |
| `cycle-windows`, `cycle_focus` | never in the history; a step taken from it goes to the head | the same |
| `navigate_window`, IPC `Focus` | `navigate_window` raises and focuses it with no flight; `Focus` refuses it | raised and focused with no flight |
| `activate`, cause `click` | focused, and a focus request returned; the answer enters no history | the same |
| `activate`, cause `click_release` | no flight, whatever `auto_navigate_on_click` says | the same |
| `activate`, cause `native`; `observe_focus`; `focus_result`; `focus_logical` | focus recorded, history untouched, no flight | the same |
| `hover` ([POINTER.md](POINTER.md#screen-pinned-windows-and-widgets)) | its motion is forwarded; `focus_follows_mouse` never focuses it, and nothing beneath a pinned widget is focused either | its motion is forwarded; `focus_follows_mouse` focuses it where it stands, before the canvas window beneath it; history untouched, and the native echo of that focus neither raises nor flies |
| pick mode, below `zoom.interact_min` | never a pick target: `hit` and `input` answer `pick: false`, `input` passes, `pick` does nothing | never a pick target: it stays interactive, also over a canvas window that is one; `pick` does nothing, and its drag and its `pass_mouse` button claims are those of any zoom |
| `begin_drag` | refused, and nothing is focused | accepted: raised and focused, then the [screen-space drag](#dragging-a-pinned-window), at every zoom; a pinned widget is refused as a widget |
| `begin_resize`, `begin_native_resize`, a size transaction begun by an action or an IPC `Resize` | refused | refused |
| the size transaction of its rule's `size`, as it maps ([A rule's `size`](#a-rules-size)) | begun | begun |
| `grow-window`, `shrink-window`, `fit-window`, `fit-window-snapped`, `fill-window` (with the capability), `zoom-to-fit-snapped` ([SIZES.md](SIZES.md#widgets-screen-pinned-windows-and-rules)) | focused: nothing happens, without an error | the same; a fit or fill it had before it was pinned stays with it |
| a move gesture ([GESTURES.md](GESTURES.md#dispatch)) | grab-proof: the gesture falls back to a pan and nothing is focused; a pinned widget too, and nothing beneath it is reached | state `swipe_move`: the same [screen-space drag](#dragging-a-pinned-window) is installed, then the window is raised and focused, as upstream's `GestureTarget::Pinned` arm does |
| a resize gesture | falls back to a pan | a native `swipe_resize` in screen points, with no snapping or cluster |
| a gesture in progress on a slot whose window maps as a widget | its drag ends at once, with its edge pan; the gesture goes on with nothing to move | a pinned slot whose window maps keeps its pin, and the [screen-space drag](#dragging-a-pinned-window) moving it goes on; mapped as a widget it keeps the pin and the drag ends |
| `send-to-output` | nothing happens | the pin is bound to the output adjacent to its own, keeping its place on the screen, clamped until the whole frame is on that output (`send_pinned_to_output`); `dirty` when the pin changed; nothing is raised |
| a hot corner, a gesture's threshold or hold action | runs the action it is bound to through the same dispatch, so every row above holds | the same |
| `state_event`, the `subscribe` line | `is_widget` is filled | listed under `pinned`, left out of `windows` |

`toggle-pin-to-screen` and `move-to-bookmark` are ordinary actions: whatever
fires them (a key, IPC, a hot corner, a gesture), upstream's action prelude
runs first, so an open cycle ends and the output's scroll momentum stops.

The hit order every one of these reads is that of `hit`, `input` and `hover`:
the windows pinned to the output, the canvas windows, the widgets, each in
stacking order from the top. `focus-center` alone reads the canvas windows
only.

## Pass rules

A rule's `pass_keys` and `pass_mouse` hand bindings of the canvas to an
application. Nothing is delivered by the controller, and no key or pointer
event is made up for it: the controller says which bindings to withhold, and
the shell then lets the event through as one nothing was bound to.

### `pass_keys`

Upstream asks on every key press: the **focused** window's live rule first,
and only if that does not allow the combo, the binding. The shell holds its
key bindings as global hot keys, so the same decision is reported ahead of
the press, in `snapshot.pass_keys`:

| Value | Meaning |
| --- | --- |
| `null` | nothing is passed |
| `true` | every key binding is passed (`pass_keys = true`) |
| `[COMBO, …]` | the bindings on these combos are passed |

A `COMBO` is spelled as the `bindings` reply spells a key binding's `combo`
(`mod+q`, `ctrl+shift+Return`), so the two compare as text. A list is the
rule's merged list in rule order, a combo on a key no binding names included.
A key outside the key table that no `[keybindings]` entry names is written as
its keysym (`alt+0xffd6`).

The focused window is the one that **holds the keyboard**: the logically
focused window once its focus is settled, that is confirmed by `focus_result`,
observed (`observe_focus`, `activate` with cause `native`) or answered
`focus_logical`. A passed key goes wherever the keyboard natively is, so
`pass_keys` is `null` while a focus request is in flight for a window other
than the one last seen holding the keyboard natively, after such a request
failed, after `focus_lost` and after `clear_focus`, and takes the window's
value again when its focus settles. A request for the very window the last
native observation names takes nothing from it: that window still holds the
keyboard, so its value stands while the request is in flight and if it fails.
It is `null` for a stand-in and for a detached slot: upstream skips the test
while a suspended window holds the focus, and neither has a client.

Sloppy focus ([POINTER.md](POINTER.md#hover)) is one more way the focus
moves, and the same rule covers it. A `hover` that moves the focus moves the
intent at once and asks for the keyboard, so the window the pointer left
passes nothing from that command on, and the window under the pointer passes
once its request is answered (`focus_result` with success, `focus_logical`)
or its answer arrives as an observation, the hover's echo. A hover whose
request fails, is withdrawn or is never answered leaves `pass_keys` `null`
for as long as the intent stays on that window, through the three seconds an
echo is waited for and after; a native report for it then, echo or
activation, gives it the keyboard and its value. A screen-pinned window
hover-focused this way passes like any other: `pass_keys` asks who holds the
keyboard, not the focus history, which a pinned window never enters
(`confirm_focus` is still the one rule for that). A hover over a stand-in
moves the focus to it and passes nothing.

Each entry of `bindings.keys` and `bindings.media_keys` has `passable`. It is
false for the bindings no `pass_keys` may take, `true` included:

- the binding that holds the shell's **exit chord** (`reserved`, purpose
  `exit`), whatever action it runs;
- every binding whose action is **`quit`**.

Upstream's one exemption is the VT switch (`Ctrl+Alt+F1`–`F12`), which keeps a
compositor that passes every key from locking its user out. A Mac has no VT
and no such keysym reaches the key table; the ways out of the canvas are the
exit chord and `quit`, so those two take its place. Upstream itself passes a
`quit` binding like any other.

A pass list is asked about the binding's own combo. Two upstream combos can
land on one physical chord (`mod` is Control+Option unless `set_platform` says
otherwise, so `mod+q` and `ctrl+alt+q` are one chord); the one that holds the
chord is the `combo` of the entry in `bindings`, and that is the spelling a
list must use.

A [tap binding](CONFIG.md#tap-bindings) is not a key binding and no
`pass_keys` takes it, `true` included: upstream decides a tap on a key release,
ahead of this test, which asks presses only. The entries of `bindings.taps`
have no `passable`.

### `pass_mouse`

`mouse_binding` takes an optional `window`: the window under the pointer, as
`hit` reports it. When that window's live rule claims the trigger the reply is

```json
{"binding":null,"passed":true}
```

and the shell treats the press or scroll as an unbound one. Every other reply
is exactly what it was, with no `passed` key. Its other optional argument,
`pick`, says that window is a [pick target](POINTER.md#pick-mode), and
decides whether the window may claim at all (below).

- The subject is the window **under the pointer**, not the focused one:
  upstream's `pass_mouse_target_under`, the pinned window first, then the
  topmost one, which is `hit`'s order.
- A claim is asked only once a binding has matched (an unbound press answers
  `{"binding":null}`), and only in the `window` context, as upstream asks it
  for `BindingContext::OnWindow`. The table the binding came from does not
  matter: `pass_mouse = true` claims the `anywhere` pan (`mod+left`) over its
  window. On the canvas nothing is claimed, whatever `window` says.
- A list holds `[mouse.*]` combos (`alt+left`, `mod+wheel-scroll`,
  `mod+trackpad-scroll`), compared exactly, as upstream's `PassList::allows`
  compares them. The combo asked about is the one the binding matched under.
- A wheel scrolls as `wheel-scroll` and a finger as `trackpad-scroll`; a claim
  on one leaves the other a binding.
- A screen-pinned window and a widget claim like any other window. A stand-in
  and a detached slot claim nothing: there is no client to pass a press to.
- **Below `[zoom] interact_min`** upstream gates every claim on pick mode,
  site by site, and so does the lookup:

  | Under the pointer, its output in pick mode | A button | A scroll, a wheel notch |
  | --- | --- | --- |
  | a canvas window, which is a pick target (`pick: true`) | claims nothing: it has no pointer focus to forward to, so a binding whose modifiers are held stays the canvas's and a bare press is the pick's, `{"binding":null}` with no `passed` | claims nothing: the bound scroll stays a binding, the bare one is looked up again on the canvas ([POINTER.md](POINTER.md#pick-mode)), a notch runs its action |
  | a screen-pinned window, never a pick target | **claims as at any zoom**: upstream's `try_pinned_button` asks with no gate, and the window is drawn at its own size and takes the press | claims nothing: `on_pointer_axis` and `pass_mouse_claims_notch` both ask `!pick_mode()`, whatever is under the pointer. The pin's own output is the one asked, so a window pinned on an output above the threshold keeps these claims |

  `pick` is the hit's to say: a lookup that names a canvas window without it
  is answered as above the threshold. A widget that is not pinned is the
  one case this does not reach, see
  [Differences](#differences-from-upstream).
- **A fullscreen window claims with no gate at all.** Upstream's
  `fullscreen_claims` asks its `pass_mouse` at the button site, the notch
  site and the scroll site alike, ahead of every pick-mode test ("a pinned
  window's *button* claims and a fullscreen window's claims still apply",
  upstream's [`docs/window-rules.md`](https://github.com/malbiruk/driftwm/blob/df3de27b26c7998e8a460cffd8a4925cbed3a322/docs/window-rules.md)). `hit` reports it on its own output, where nothing
  else is drawn, and never as a pick target: its output is parked at zoom 1
  and it is no canvas window. The lookup holds that whatever its caller says:
  `pick` is ignored for a fullscreen window, a press, a scroll and a notch
  it claims are all `passed`, and none of them is looked up again on the
  canvas. A claimed press or scroll ends no fullscreen; an unclaimed one
  follows [the exit rules of its site](FULLSCREEN.md#leaving).
- **Chrome is never `pass_mouse`'s to give**, upstream says of its title bar,
  close button and resize borders. No chrome can be hit here: `hit` tests a
  window's frame, a `server` window's drawn title bar lies above the frame
  ([RENDER.md](RENDER.md#the-decoration-mode-on-macos)) and is no hit, and no
  resize band is drawn for a live window. A press there is a press on the
  canvas.

Two triggers are new, upstream's discrete wheel notch: `wheel_up` (away from
the user) and `wheel_down`, with no `source`. They are a lookup of their own
(`mouse_wheel_step_lookup_ctx`), apart from `scroll`: the reply is a binding
only when the notch is bound to an action (`kind` is `action`), since
upstream's notch site runs nothing else, and `passed` when the window claims
`wheel-up` or `wheel-down` under those modifiers (`pass_mouse_claims_notch`).
A passed notch, like an unbound one, is not the end of the wheel event:
upstream then looks the same event up as a continuous scroll. The shell does
both in that order for a discrete wheel event, never for a trackpad's precise
scroll, which has no notches: the notch first, in the pointer's own context
(the 150 ms canvas lock after a finger pan belongs to the continuous lookup
alone); a notch bound to an action runs it once per notch, ten at most for
one event, and the event ends there; anything else, `passed` included, goes
on to `scroll`. Listing `mod+wheel-down` claims the notch and leaves a
`mod+wheel-scroll` zoom firing. Over a pick target the notch lookup is the
plain one: upstream's notch site stands ahead of its pick-mode press and
scroll handling, so a bare notch bound there runs, and nothing is retried on
the canvas.

Trackpad gestures (`gesture_begin`) ask no claim: upstream's swipe, pinch and
hold dispatch never consults `pass_mouse`.

## Dragging a pinned window

`begin_drag` on a screen-pinned window raises and focuses it and installs
upstream's pinned move grab, in that order, as upstream's `try_pinned_button`
does (`raise_and_focus`, then `start_pinned_move`, `MoveGrab::new_pinned`).
The move gesture installs the
same one: over a pinned window `gesture_begin` answers `swipe_move` as for a
canvas window, the drag is installed, then the window is raised and focused
(upstream's `try_start_gesture_move`, its `GestureTarget::Pinned` arm), and
each `gesture_update` moves it by the fingers' displacement
([GESTURES.md](GESTURES.md#dispatch)). `gesture_to` and `end_gesture`
are the commands of any drag:

- The frame follows the pointer **in screen space**: its top-left is where it
  was at the press plus `screen_delta`, in screen points whatever the zoom,
  rounded to a whole point, a half away from zero. A canvas window moves by
  `screen_delta / zoom` in the world; a pinned one by `screen_delta` on its
  output.
- **The frame is not clamped; the pointer is.** Upstream's grab writes the
  pin where the pointer takes it, so a frame can be dragged part of the way
  off its output and is drawn clipped. It never goes all of the way:
  upstream's cursor is confined to an output (`clamp_to_output` in its
  pointer motion), so the point the frame was taken by stays on one. The
  shell's pointer is not confined, so the controller holds it, as the item
  on the pointer's output below says. (A pin itself is clamped where upstream
  clamps it: by its rule when it maps, by `send-to-output`, and when its
  output changes.)
- **No snapping, no cluster, no edge pan.** `group` is ignored: a pinned
  window has no cluster. The pointer at the output's edge pans no camera.
- **The pointer's output takes the pin.** With `gesture_to`'s `pointer` on
  another connected output the pin is bound to that output, at the point that
  keeps the frame under the pointer, as upstream's "dragging it across
  monitors reassigns it". Without `pointer` the pin stays on the output the
  drag is on. With `pointer` on no output it stays there too, and the pointer
  is taken as held at that output's nearest point (the far bound one point
  short of the edge), as upstream's cursor is: `screen_delta` is reduced by
  the overshoot. `pointer` is read as the press point plus `screen_delta`,
  which is what the shell sends. The cursor itself is macOS's and is not
  moved: after an overshoot it has to come back to the output's edge before
  the frame moves again, where upstream's held cursor moves it at once.
- The canvas frame follows after each command, as after any other.
  `placements` keeps reporting the pin's `screen_rect`.
- It is the one pointer gesture: every guard a drag raises holds (a second
  `begin_drag`, a pin, an IPC `Move`). Each output's flight and momentum stop
  when it is installed, and its output's edge pan is cleared when it ends, as
  upstream's move grab does both.
- It is installed by the one `install_drag` every drag goes through, behind
  the same guards: no drag of a window whose
  [sizing action](SIZES.md#other-interactions) is still owed its size is
  installed, pinned or not. A sizing action's window is never pinned, since
  a pin waits for the transaction; the pinned window the guard refuses is one
  still owed [its rule's `size`](#a-rules-size).
- **The zoom does not matter**, pick mode included. Below
  `[zoom] interact_min` a pinned window is no pick target and its drag is
  this one, by the same displacement. `pick` does nothing with it.
- A move gesture's pointer is the gesture's own, held inside the output the
  gesture began on as upstream warps its cursor, so a gesture never takes a
  pin to another output; it drives only the drag it installed, as with a
  canvas window.
- A window that closes, or becomes a stand-in and so is unpinned (at a close,
  or as a slot a discovery pass keeps: `adoption_complete`), ends its drag,
  and the close logs its one
  [lifecycle event](EFFECTS.md#lifecycle-events) like any other, `close` or
  `close_to_standin`. A slot whose window maps under the drag keeps its pin
  and the drag, unless it maps as a widget. An output that is removed ends
  every gesture.
- Nothing is installed while the pin's output is gone (`the window's output
  is not connected`), and a pinned widget is refused as a widget.
- **A fullscreen output takes no pin.** It draws its fullscreen window alone
  ([FULLSCREEN.md](FULLSCREEN.md#the-pointer-and-other-outputs)), so while
  `gesture_to`'s `pointer` is over one the drag is frozen: the pin stays
  where it was, on the output it was on, and the drag goes on from the
  pointer's displacement once the pointer has left it again. That is
  upstream's `MoveGrab::motion` ("a window dragged there would just
  vanish"). No output becomes fullscreen under a drag: an enter is refused
  while any gesture is installed, `a window is under an interactive move or
  resize`. A window whose own pin is on a fullscreen output is hidden there
  and is not taken from elsewhere (`the window's output is fullscreen`); a
  press on that output is a grab, which ends its fullscreen first, and the
  pinned window is then drawn again and dragged like any other.
- `begin_drag` raises and focuses the window ahead of the grab, for a pinned
  window as for a canvas one, and its reply is the focus request
  (`{"effect":…}`, null for a slot with no window), which the shell performs
  as it performs a click's. That is upstream's press: `try_pinned_button`
  for a pinned window and the move arm of `on_pointer_button` for a canvas
  one call `raise_and_focus` and then start the grab. A pinned window holds
  that focus outside the focus history. The move gesture installs its drag
  first and then raises and focuses, as upstream's `try_start_gesture_move`
  does. A `begin_drag` that is refused focuses nothing
  ([NAVIGATION.md](NAVIGATION.md#differences-from-upstream)).

### Resizing a pinned window

`begin_native_resize` follows upstream's `apply_pinned_resize`
(`src/grabs/resize_grab.rs`) takes the pointer in the pin's output, clamped to
`[0, size - 1]` on each axis, and its screen-space displacement since the
press as the size change, unscaled by the zoom: subtracted for a left or top
edge, added for a right or bottom one. The size is bent onto a locked aspect
ratio, then clamped to the window's constraints, and configured on the client.
There is no snapping and no cluster. A left or top edge moves the pin's
`screen_pos` when the client commits the new size, so the opposite edge stays
put. The edge of a resize binding is inferred against the pinned rectangle in
screen space.

## `layer_order`

Read, recorded and ignored. Upstream orders layer-shell surfaces by it (the
panels and overlays of one wlr-layer, and the layers a rule puts on the
canvas) and documents it as "Ignored for regular windows"
(upstream's [`docs/config.md`](https://github.com/malbiruk/driftwm/blob/df3de27b26c7998e8a460cffd8a4925cbed3a322/docs/config.md)). A Mac has no layer surfaces, and every window here is a
regular one, so this port ignores it as upstream does: the window's `rule`
lists the value, `rule.not_applied` names `layer_order`, and `placements`,
`hit`, `input` and `focus-center` are in stacking order within each bucket
whatever a rule says.

## Wire contract

One command is new, and the shell must send it:

| `command.op` | Fields | Result |
| --- | --- | --- |
| `outputs_settled` | none | `{dirty}`: true when a pin moved to another output |

The shell answers every screen change by removing all its outputs and
registering the current ones again. `outputs_settled` after the last
`register_output` is the first moment the controller can tell a display that
is gone from one that came straight back. Without it a pin whose display is
gone stays undrawn until a discovery pass ends. A wake, an
unlock or a change of Space is no screen change: while the displays are the
ones its panels were made for the shell puts the panels back in front and
sends nothing.

What is added to existing replies:

| Where | Field | Meaning |
| --- | --- | --- |
| `snapshot.windows[]` | `widget` | bool |
| | `pinned` | null, or `{output, screen_rect}`: the output id and the rectangle in global screen points; `screen_rect` is null while that output is disconnected |
| | `rule` | null, or the applied rule under upstream's names: `opacity`, `decoration` (`"client"`, `"server"`, `"minimal"`, `"none"`), `blur`, `widget`, `pinned_to_screen`, `position`, `size`, `output`, `fullscreen`, `focus_on_open`, `suspend_on_close`, `restore_windows`, `preserve_aspect_ratio`, `pass_keys` and `pass_mouse` (`"none"`, `"all"`, `"only"`), `border_width`, `border_color`, `border_color_focused`, `corner_radius`, `shadow`, `layer_order`; and `not_applied`, the names of the set fields that change nothing here |
| `snapshot.placements[]` | `pinned` | bool; a pinned placement's `screen_rect` is its pin's, in global screen points, and `world_local_crop` is in the same points. The shell draws it from that rectangle, above the canvas windows, at zoom 1 ([RENDER.md](RENDER.md#layers-and-the-pinned-space)) |
| | `widget` | bool; drawn below the canvas windows |
| | `opacity` | what the window is drawn at, upstream's `effective_opacity`: a rule's or an IPC write's value in both focus states, else 1 for a widget, else `[decorations] opacity_focused` or `opacity` by the logical focus. 1 with no rule and a default config, and 1 for every window without a source, as upstream draws a stand-in. The placement's `decoration.opacity` is the same number from the same function |
| `hit`, `input` | `widget`, `pinned` | bools, so the shell can refuse to start a move or resize on what it hit |
| `attach` of a new window | `transaction`, `effects` | only when a size transaction began with this map, for this window's rule's `size` or for that of a window that was waiting: the transaction's id, and its effect as the one entry of `effects` ([A rule's `size`](#a-rules-size)) |
| `native_resize_result` | `transaction`, `effect` | unchanged keys; when the result ends its transaction they can be those of the next waiting window's size transaction |
| `begin_drag`, `begin_resize` | `effect` | the focus request of the press, as `activate` with cause `click` returns it: the window is raised and focused ahead of the grab ([Dragging a pinned window](#dragging-a-pinned-window)) |
| `begin_native_resize` | `effects` | the same request as its one entry; `effect` is the transaction's |
| `snapshot` | `pass_keys` | null, `true` or a list of combos: what the window that holds the keyboard passes ([Pass rules](#pass_keys)) |
| `bindings.keys[]`, `bindings.media_keys[]` | `passable` | bool: false for the exit chord's binding and for `quit` |
| `mouse_binding` | `window` (request) | optional window id, the window under the pointer; a claimed trigger answers `{"binding":null,"passed":true}` |
| | `pick` (request) | optional bool, that window is a pick target as `hit` reports it ([POINTER.md](POINTER.md#pick-mode)): it then claims nothing ([`pass_mouse`](#pass_mouse)) |
| | `trigger` (request) | also `wheel_up` and `wheel_down`, upstream's wheel notch |
| `gesture_begin` over a screen-pinned window | `gesture.state` | `swipe_move` for a move trigger, with the focus request in `effects`; the state `swipe_pinned` and its `note` are gone |

`snapshot.placements` stays the single list of what to draw, bottom to top
within each output: **widgets, canvas windows, the windows pinned to that
output**, each in stacking order. `hit` and `input` resolve in the reverse
order. `mouse_binding` takes no point: its `context`, its `window` and its
`pick` are the shell's, from the hit.

`rule` is null for a window no rule matched, until an IPC `Opacity` write
gives it an otherwise empty one. `decoration`, the border fields,
`corner_radius`, `shadow` and `opacity` are what the window's `decoration` in
the snapshot is resolved from while it has a source, and `blur` makes its
`decoration.blur` true, which the shell's compositor frosts
([EFFECTS.md](EFFECTS.md#blur)): the rule kept here is the only one the
renderer is given, so what [Matching](#matching) says of retitles and reloads
holds for what is drawn too.

### Actions

| Action | Effect |
| --- | --- |
| `toggle-pin-to-screen` | as above; `dirty` when the pin changed |
| `move-to-bookmark <name>` | centers the focused canvas window's frame on the bookmark's point, each coordinate rounded, and raises it; a focused stand-in moves in place. A missing bookmark, a widget and a pinned window are passed over without an error |

Both report `implemented: true` in `bindings` and `mouse_binding`.

### IPC

| Request | Reply |
| --- | --- |
| `{"Pin":{}}`, `{"Pin":{"window":S}}` | `{"Pin":bool}` |
| `{"Pin":{"window":S,"value":bool}}` | `{"Pin":bool}`; `dirty` only when it changed. Unpinning by selector raises the window and focuses nothing |
| `{"Opacity":{}}`, `{"Opacity":{"window":S}}` | `{"Opacity":n}`, what the window is drawn at |
| `{"Opacity":{"window":S,"value":n}}` | `{"Opacity":n}`; pins the value until the window is gone. Never `dirty`: it is not saved |

Refusals, in upstream's words: `stand-ins can't be pinned` (a detached slot of
any kind), `no output to pin to`, `opacity must be between 0.0 and 1.0` (not
clamped), `no window with id N` for an `Opacity` on anything that is not live,
`window #N is a widget and cannot be focused`, `widgets cannot be suspended`,
`this window has no canvas position to move: it is pinned, fullscreen, or not
on screen yet`, and `this window has no canvas size to set: it is pinned,
fullscreen, a widget, or not on screen yet`, which a `Resize` write answers for
a pinned window or a widget whether or not the shell can deliver a size: it
comes before the [gate](SIZES.md#the-gate) that refuses every other resize
without the capability. `size must be positive` comes first.

`State`: a pinned window is left out of `windows` and listed under `pinned`
with its output's stable id and the `position` and `size` a `pinned_to_screen`
rule takes, sorted by output and position. `is_widget` is filled.

## Persistence

- **Widgets never enter the session store**, as upstream documents. `save`
  writes nothing of a widget: no window, no title, no focus. At the next
  launch the window is discovered as a new one and maps by its rule again; a
  position it was moved to by IPC is gone.
- **No rule is saved**, and no IPC opacity: every window maps again and
  resolves its rules against the config of that launch.
- **A pin is saved with its slot**, in the field `pins`
  (`{"<window>":{"output":ID,"screen_pos":[x,y]}}`), which is always written
  and empty while nothing is pinned. The slot's saved frame is
  the canvas frame the pin showed. At the next launch a window that takes its
  slot back is pinned where it was. A pin read from the file waits for its
  own output to register, whatever order outputs arrive in, and is clamped
  into it when it does; if the shell's `outputs_settled`, or the end of a
  discovery pass, finds that output still missing, the pin moves to the first
  output that is connected, and the reply (`outputs_settled`'s or
  `adoption_complete`'s) reports `dirty`.
- A saved pin that names a stand-in, a missing window or an output the file
  does not hold refuses the `load`.
- So a pin outlives a restart only for a window that comes back and adopts its
  slot. At `adoption_complete` a slot whose window did not return is dropped,
  or becomes a stand-in and is unpinned. Until a discovery pass ends, and for
  the whole of a run that has none (the shell sends `adoption_complete` only
  while it manages windows), the slot is neither live nor a stand-in and keeps
  its pin: it is drawn as a pinned placement and listed under `State.pinned`,
  `Move` and `Resize` refuse it, and `Pin` answers `stand-ins can't be pinned`
  even to a read, upstream's selector rule meeting a state upstream never has.

## Differences from upstream

- **A pin outlives the canvas.** Upstream's session file never holds one: its
  windows die with the compositor, and a restored window is a stand-in on the
  canvas. Its only statement about persistence is that a toggled pin survives
  a *config* reload because it lives on the stage. That holds here. Saving the
  pin with the slot is the macOS rule of [LIFECYCLE.md](LIFECYCLE.md): the
  application outlives the canvas, so a window that is still open gets its
  slot back as it was. A slot that becomes a stand-in is unpinned, as
  upstream's are.
- **`size` is gated, placed for the size asked, and asked in turn.** Upstream
  configures the client to the rule's size first and places it on the
  follow-up commit for the size the client committed. Here the window is
  placed for the size asked as it maps
  ([A rule's `size`](#a-rules-size)), which is the same frame whenever the
  window grants the size. A window that grants another size keeps the
  top-left of the frame asked for, as IPC `resize` leaves it, where upstream
  places the size it got: its `position` then centers that size, and its pin
  and its placement are computed for it. Until it answers the window is on
  the canvas at its own size, where upstream shows it only once it is sized.
  Upstream configures every ruled window at once; here they are asked one
  after another, so the later of several that map together stand at their
  own size until their turn. Without `native_resize_capability` nothing
  is asked at all, and `rule.not_applied` names `size`.
- **`fullscreen` is applied only when the shell can deliver a size**
  ([FULLSCREEN.md](FULLSCREEN.md#the-gate)), and not during the launch pass.
  Otherwise it is recorded and named in `not_applied`. With a `size` beside
  it the size is owed, not asked first: one transaction takes the window
  from its own size to the output's, where upstream's client is configured
  twice.
- **`preserve_aspect_ratio`** is applied to a pointer or gesture resize, as
  upstream's `locked_ratio_for` and `constrain_to_ratio`: the window keeps the
  width / height it has when the grab begins, an edge driving its own axis and
  a corner the axis that moved farther relative to the ratio, with no snap and
  no cluster ([NATIVE_RESIZE.md](NATIVE_RESIZE.md#pointer-resize)). The sizing
  actions, IPC `resize` and a rule's `size` are not bent, as upstream's are
  not. The application's own limits may bend the ratio.
- **`layer_order` is ignored, which is upstream's own rule for a window.**
  It is listed in `not_applied` because the field does nothing here, not
  because something is missing: upstream applies it to layer-shell surfaces
  only (upstream's [`docs/config.md`](https://github.com/malbiruk/driftwm/blob/df3de27b26c7998e8a460cffd8a4925cbed3a322/docs/config.md): "Ignored for regular
  windows"), and there are none
  on a Mac ([`layer_order`](#layer_order)).
- **`pass_keys` follows the keyboard, not the logical focus alone.** Upstream's
  focused window is the one its seat delivers keys to. Here the canvas's
  focus is an intent, and a passed key goes to whatever natively holds the
  keyboard, so a window's `pass_keys` counts only once its focus is settled
  ([Pass rules](#pass_keys)), a hover's focus like any other. The shell
  learns of it from `snapshot.pass_keys` and stops holding the hot keys;
  upstream decides per key press. The cost is on the cautious side: while a
  request for another window is in flight, failed or unanswered, nothing is
  passed, although the window that last held the keyboard may hold it still.
- **The exit chord and `quit` are never passed**, in the place of upstream's
  VT switch. Upstream passes its `quit` binding like any other.
- **A pass list names the combo that holds the chord.** Where two upstream
  combos share one physical chord, only the one that is the binding's `combo`
  is asked about, for keys and for the pointer alike. Upstream has one
  modifier state per event and no such choice.
- **A widget's claim below `[zoom] interact_min` still holds.** Upstream's
  button and scroll sites drop every claim there but a pinned window's button
  claim, a widget's included, although a widget keeps its pointer focus and
  its documentation speaks of canvas windows only. The lookup is told the
  window and whether it is a pick target, not which output the pointer is
  on: a canvas window's gate is `pick`, a pinned window's is its pin's
  output, and a widget that is not pinned has neither, so its claims are
  honoured at every zoom.
- **A wheel line is a notch.** Upstream accumulates a high-resolution wheel's
  sub-notch deltas to whole notches. macOS reports a discrete wheel in whole
  lines, more than one for a fast turn, so the shell runs a notch's action
  once per line, ten at most for one event as upstream caps a flick, and
  keeps no accumulator.
- **Shift turns a wheel sideways.** While Shift is held AppKit hands a
  discrete wheel's vertical lines over as horizontal ones (the vertical axis
  reads 0, the sign is kept); upstream's wheel stays vertical under any
  modifier. The notch site reads the lines back from the horizontal axis
  then, so a shift-qualified notch (`mod+shift+wheel-up`) and its claim are
  asked. A sideways wheel turned under Shift arrives as the same event and
  counts as a notch too, where upstream's notch site reads the vertical axis
  alone. The continuous lookup is not corrected: a wheel `scroll` under Shift
  still carries horizontal lines only, so a shift-qualified `zoom` binding
  zooms nothing and a `pan-viewport` one pans sideways. The swap was read off
  wheel events built in memory (macOS 27.2); no wheel was turned.
- **The fullscreen legs are the same lookup.** Upstream's fullscreen window
  claims in its own branch of each site (`fullscreen_claims`), ahead of every
  pick-mode test, and is the subject of a press, a scroll and a notch
  anywhere on its output. Here `hit` reports the fullscreen window where it
  is drawn, never as a pick target, so its claims hold for all three with no
  gate, and a claimed press or scroll is the application's and ends nothing.
  In the band a smaller fullscreen window leaves, `hit` reports nothing: the
  lookup is the canvas context's and nobody claims, where upstream still asks
  the fullscreen window
  ([FULLSCREEN.md](FULLSCREEN.md#differences-from-upstream)).
- **A pinned window has no compositor title bar to drag.** Its move binding
  and move gesture operate in screen space, as do normal edge and bound
  resize grabs. A widget still rejects manual moves and resizes and keeps
  its application-owned clicks. Native title-bar and third-party behavior
  remain separate runtime acceptance obligations.
- **A pinned drag's pointer is held in arithmetic, not on the screen.**
  Upstream confines the cursor itself to an output, and that is all that
  bounds its pinned move. macOS owns the cursor here: it goes out of a
  `--windowed` panel, and the controller takes it as held at the edge of the
  drag's output. After an overshoot the cursor has to travel back to that edge
  before the frame leaves it, where upstream's moves
  at once: upstream clamps each relative motion, so its cursor never
  accumulates an overshoot, and a report here is an absolute position. A move
  gesture's pointer is the controller's own and is held as upstream's is.
- **Pins leave a removed output only at `outputs_settled`.** Upstream rehomes
  a pin the moment its output is unplugged. The macOS shell learns of a
  screen change as one notification and answers it by removing every output
  and registering the current ones, so a removal by itself says nothing about
  which display is gone. The controller therefore
  waits for the shell's `outputs_settled` (or the end of a discovery pass);
  until then the pin is bound to its removed output and drawn nowhere.
- **A window pinned by toggle that closes has no spatial follower.** Upstream
  keeps the snap rectangle such a window had before it was pinned and tests
  the focus history against that stale rectangle when it closes; a window
  pinned by its rule never has one. Here no pinned window has one, however it
  was pinned.
- **Chrome is zero.** Native frames include their title bar, so a rule's frame
  is the window's frame, and no decoration mode changes any geometry.
  `decoration` changes what is drawn around the frame and what a `screenshot
  window` frames, never the frame ([RENDER.md](RENDER.md#the-decoration-mode-on-macos)).
- **IPC `Move` and an IPC unpin of an unfocused widget do not re-stack** beyond
  the layer rule; `Move` raises nothing, as before.
- **A widget that maps does not hand the focus to the head of the focus
  history.** Upstream re-asserts keyboard focus there; here the focus simply
  stays where it was.
- **Clamping a pin whose output returns.** A saved pin is clamped into its
  output's bounds when the output first registers in a run, since the display
  may have changed size between launches, and again whenever the output
  registers at a size other than the one it had. An output that comes back
  unchanged clamps nothing, so a pin made by hand with part of its frame off
  the display stays there for the rest of the run.
- **`[decorations] opacity` and `opacity_focused`** follow the canvas's logical
  focus, not native keyboard focus, and reach `placements[].opacity` and
  `decoration.opacity` through upstream's helper. A detached slot is opaque
  whatever its window's rule or `Opacity` write was, like a stand-in.
- **`focus-center` takes no widget.** Upstream's walk under the pointer skips
  a pinned window and does reach a widget, which it then raises, focuses and
  flies to like any window. Here the candidates of `center-window`,
  `center-nearest`, `focus-center` and `cycle-windows` are one set, the canvas
  windows, and a widget is flown to by nothing: `navigate_window` raises and
  focuses one where it is.
- **A click on a widget raises it among the widgets.** Upstream focuses a
  clicked widget without raising it. `activate` raises what it focuses, and
  the stacking rule then keeps every widget below every window, so only the
  order of overlapping widgets can differ.
- **`send-to-output` takes a pin's own output as its source.** Upstream
  resolves the source geometrically, as the first output whose viewport shows
  the pin's canvas frame; with two outputs showing the same canvas region that
  can be another output than the one the window is pinned to.

## Verification boundary

[`crates/desktop/tests/rules_flow.rs`](../../../crates/desktop/tests/rules_flow.rs) drives every scenario through the
exported C ABI and JSON decoder with synthetic observations, on two outputs
neither of which is at the global origin: matching by app-id glob, title glob,
both, and a regex, with the merge order; a position rule; widgets (stacking,
cycling, refusals, IPC `Move`); snapping and cluster exclusion; rule pins and
toggled pins under pan and zoom; IPC `Pin`, `Opacity`, `Move`, `Resize`,
`Focus`; `move-to-bookmark`; retitle, reload and relaunch adoption; hit order;
the four window navigation actions, the three causes of `activate` and
`navigate_window` on a layout with a widget and a pinned window in the way,
each against a control that shows what the unfiltered search would have
taken; `send-to-output` with a widget and with a pinned window focused, and
the `state_event` line afterwards; a move and a resize gesture begun over a
widget, over a pinned window (the move drags it in screen space and raises
and focuses it, the resize is claimed and does nothing) and over a canvas window, and a
move gesture whose slot is adopted as a widget; an open cycle and a coast ended by
`toggle-pin-to-screen` and by `move-to-bookmark`, and both run from a hot
corner;
a rule's `size` without the capability and with it: five ruled windows that
map together, a canvas window by `position`, a second one, a widget, a
rule-pinned window and one the placement policy places, each placed for the
size asked with the frames, the pin and the flight worked out by hand for odd
sizes, each standing centered in that frame at its own size, and each asked
in map order in the reply that ends the transaction before it; one that
closes and one that loses its source while they wait; a window that grants
less; the drag and the unpin of the pinned one refused while its size is
owed; a window, a widget and a pinned window that have the size already; an
adopted slot; a ruled window that waited out a drag, asked in the reply
of the next new window's `attach`, with a queue dropped when the shell says
it can no longer deliver a size; a waiting window the user sizes first (IPC
`resize`, the size it already has, a fit, a resize drag and a native one),
which is then not asked, against one that is asked when another window's
transaction ends; three windows of one rule without a `position` that map
together and cascade by the frames asked for, and two under `auto`
placement that end where two windows of that size already do;
a close with only a widget or a pinned window left in view, and the close of
a pinned window or a widget lying over a canvas window; a detached slot under
a drag adopted as a widget; output removal with and without a settle, and the
shell's own order for a screen change (remove both, register both or one,
`outputs_settled`), with a display that returns smaller; the save file and
two next launches. Expected rectangles are derived by hand from upstream's
conventions. The `hover` and pick-mode rows of the table above are driven by
[`crates/desktop/tests/pointer_flow.rs`](../../../crates/desktop/tests/pointer_flow.rs)
([POINTER.md](POINTER.md#evidence-and-limits)), the same way, and the sizing
rows by [`crates/desktop/tests/sizes_flow.rs`](../../../crates/desktop/tests/sizes_flow.rs)
([SIZES.md](SIZES.md#verification-boundary)). In the `size` scenario the test
plays the shell's part and answers the resize effects itself: no native window
was resized, by a rule or otherwise.

[`crates/desktop/tests/passthrough_flow.rs`](../../../crates/desktop/tests/passthrough_flow.rs) does the same for
the pass rules and the pinned drag, on the same two outputs, in 19 scenarios:
`pass_keys` as `true`, as a list, as two lists unioned and as a list under a
sticky `true`; through a focus request confirmed, failed and answered
`focus_logical`, `focus_lost`, a native activation, a click, `clear_focus`,
a request, in flight and failed, for the window still observed natively,
the focus a close hands on, a stand-in and a detached slot; through sloppy
focus, where a hover's request is confirmed, answered by its echo, settled
logically, failed and then echoed late, and withdrawn and left to expire
before a report that is an activation, with a pinned window and a stand-in
hovered last; after a retitle and two reloads; `passable` on every key of a
config that binds the exit chord and `quit` twice. The `pass_mouse` scenarios
are upstream's `src/tests/pass_mouse.rs` restated as lookups: a listed combo
and its control, a combo outside the list, `true` over an `anywhere`
binding, the wheel and the trackpad under their own triggers, the bound,
claimed and unbound notch, a reload, a pinned window, and the pointer over a
window that is not the focused one; and its `interact_min` cases against
this port's pick mode: at zoom 0.4 under a threshold of 0.5 a canvas window
that claims everything keeping no binding from the canvas (a held-modifier
press, a bound scroll, a bare scroll retried on the canvas, a bound and a
bare notch, a bare press left to the pick), a pinned window keeping its
button claims and losing its scroll and notch claims, a window pinned on the
other output, above the threshold, keeping them all, the pinned window
dragged there, and every claim back at zoom 1. Its fullscreen cases are
`crates/desktop/tests/fullscreen_flow.rs`'s (a fullscreen window's claims at all three
sites, with and without `pick`, and its `pass_keys`); its title-bar cases
have nothing to run against here. A pinned window is dragged at zoom
0.5 on an output that is not at the global origin: by the screen
displacement and not by twice it, a half rounded, unclamped past two
corners, with the pointer in the edge-pan zone against a canvas window's
control, saved and loaded, and unpinned; across to the other output and
back; with the pointer on no output, above the output and past its far
corner, and in the 64 points above an output that starts that far down the
screen (a `--windowed` panel's still starts inside its display), where the
frame stays drawn and hit; against every other gesture, a
trackpad move's serial included; by the move gesture, to the same numbers,
raised and focused, its pointer held at the gesture output's last column,
as a cluster move, with the pointer's own drag taking over, and over a
pinned widget, where the gesture pans; under a close and a suspend, each
logging its one lifecycle event; and as a detached slot through its
adoption, its adoption as a widget, and a discovery pass that keeps it as a
stand-in. Six windows, two of each bucket, three of them ranked by
`layer_order`, are read back from `placements`, `hit` and `focus-center` in
plain stacking order, with the rank in `rule` and in `not_applied`.

Both files are evidence of the controller's arithmetic and ordering only.
Nothing in `passthrough_flow.rs` shows that a hot key was unregistered, that a
key or a press reached an application, or that a pinned window followed a
real pointer: the shell's use of `pass_keys`, `passable`, `passed` and the
accepted `begin_drag` is its own to verify, and
the run made once the two were built together reached none of it. Nothing here
shows that a native window is drawn at an opacity, blurred, kept above
another, or receives a click; that a real application's bundle identifier or
title matches a rule; or what a real display reconfiguration does. The order
the tests replay (every output removed, the current ones registered, then
`outputs_settled`) is the one `native/app/Desktop/Desktop+Rendering.m` and `Desktop+Session.m` send from
`screensChanged`, `cleanup` and `openPanels`, read there and not observed with
a second display. The shell's use of `opacity`, `widget` and `pinned` is its
own to verify.
Upstream's behaviour was read from the files named above, not run.

One more scenario in the same file crosses this contract with
[RENDER.md](RENDER.md#verification-boundary): a widget, a rule-pinned window
and a canvas window described for one frame, with the layer keys, the pinned
`screen_rect` against the camera, one opacity in `opacity` and
`decoration.opacity`, and what a `Window` and an `All` capture take of them.
