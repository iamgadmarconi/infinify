# Window rules, widgets and screen-pinned windows, ABI 1

DriftWM's per-window policy: `[[window_rules]]` matched when a window maps,
widgets fixed to the canvas, windows pinned to an output's screen, and the
bindings a window's rule takes from the canvas (`pass_keys`, `pass_mouse`).
All of it is additive to ABI 1: no existing command or reply changes shape.
The shell sends one new command, `outputs_settled`, once it has registered its
displays. A scene with no rule, no widget and no pin behaves and saves exactly
as before.

The rules are adapted from malbiruk/driftwm at
`352333a8fa1b22171492d4b71a54102045c9a19d` (GPL-3.0-or-later):
`src/handlers/compositor.rs` (a new toplevel's first sized commit),
`src/state/pinned.rs`, `src/state/mod.rs` (`is_canvas_window`),
`src/state/output.rs` (`output_for_window`), `src/state/persistence.rs`
(`screen_space_inventory`), `src/input/actions.rs` (`toggle_pin_to_screen`,
`MoveToBookmark`), `src/input/pointer.rs` (the move and resize bindings pass
over a widget; of `try_pinned_button`, the screen-space drag of a pinned
window is adapted and its resize is not) and `src/ipc/mod.rs` (`cmd_pin`,
`cmd_opacity`, the refusals of `cmd_move`, `cmd_resize`, `cmd_focus` and
`cmd_suspend`), and, for what the navigation actions, gestures and output
actions do with a widget or a pinned window, `src/input/actions.rs`
(`CenterWindow`, `CenterNearest`, `SendToOutput`), `src/input/mod.rs`
(`topmost_under`, `draggable_element_under`), `src/input/gestures/swipe.rs`
(`gesture_target_under`), `src/state/navigation.rs` (`navigate_to_window_on`)
and `src/state/pinned.rs` (`send_pinned_to_output`). The matcher, the merge and the opacity rule are not adapted:
they are driftwm-core's `Config::resolve_window_rules`, `AppliedWindowRule`
and `effective_opacity`, upstream's own code. The code is in
[`src/rules.rs`](src/rules.rs); the user contract is upstream's
`docs/window-rules.md`.

The pass rules and the drag of a pinned window are in
[`src/passthrough.rs`](src/passthrough.rs), adapted from the same commit:
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

Then, once mapped:

- A **widget** and a window whose rule says `focus_on_open = false` are neither
  focused nor navigated to.
- A window **pinned** by its rule is raised and focused where it is; there is
  no canvas position to navigate to, so `navigation` is null.
- Any other placed window is focused and navigated to as before. A ruled
  position is not a cursor placement: it navigates.
- During the launch pass nothing is focused or revealed, as before.

An `attach` that names its `logical_id` or its `world_rect` has decided the
frame itself: the window gets its rule less the placement (no `position`, no
pin, no `size`).

### A rule's `size`

A rule's `size` is a native size, and reaches a window only through the
[size transaction](SIZES.md#what-a-sizing-action-does) of
`--experimental-native-resize`. So it follows that gate:

- **Without `native_resize_capability`** nothing is asked. The window keeps
  its own size, a `position` centers that size, and `rule.not_applied` names
  `size`. This is what every run without the flag does.
- **With it**, a new window that step 2, 3 or 4 above placed is asked for the
  rule's size once it is placed, through `Controller::request_window_size`,
  IPC `resize`'s own path: the frame keeps its center and the top-left moves
  by half the difference in whole pixels, so a ruled `position`, a centered
  placement and the arrival's flight still aim at the same point. Nothing of
  the frame is written before the window has answered, and the size written
  is the one it took. The `attach` reply then also carries `transaction`, and
  the transaction's effect as the one entry of `effects`, for the shell's
  resize coordinator; `effect` stays the arrival's focus request.
  `rule.not_applied` no longer names `size`. The window's `open` is logged
  with the map, once, whatever becomes of the size; a shell that animates it
  waits for the transaction
  ([EFFECTS.md](EFFECTS.md#beside-a-size-that-is-owed)).

Still not asked, with the capability on, and still named in `not_applied`:

- a **widget** and a window the rule **pinned**, whatever size they have: no
  size transaction begins for either
  ([Differences](#differences-from-upstream));
- a window that **takes over a slot**, which keeps the slot's frame as
  upstream's adopted window does;
- a window that maps **while a drag, a resize or another size transaction is
  unresolved**: there is one transaction and nothing is queued
  ([SIZES.md](SIZES.md#a-second-action-while-a-size-is-owed)), so of several
  ruled windows that appear at once, the launch pass included, the first is
  asked and the others keep their size;
- a window whose application does not accept a size (`resize_disabled`).

A canvas window that maps with the rule's size already is asked nothing, and
`size` is not listed. The request never fails the `attach`: a size that cannot be
asked leaves the window mapped exactly as without the capability.
`preserve_aspect_ratio` and `fullscreen` stay recorded and not applied.

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
  ([below](#dragging-a-pinned-window)). Not resized: `begin_resize` and
  `begin_native_resize` refuse it. `nudge-window`, `move-to-bookmark` and the
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
| `begin_drag` | refused | accepted: the [screen-space drag](#dragging-a-pinned-window), at every zoom; a pinned widget is refused as a widget |
| `begin_resize`, `begin_native_resize`, a size transaction begun by an action, an IPC `Resize` or a rule | refused | refused |
| `grow-window`, `shrink-window`, `fit-window`, `fit-window-snapped`, `fill-window` (with the capability), `zoom-to-fit-snapped` ([SIZES.md](SIZES.md#widgets-screen-pinned-windows-and-rules)) | focused: nothing happens, without an error | the same; a fit or fill it had before it was pinned stays with it |
| a move gesture ([GESTURES.md](GESTURES.md#dispatch)) | grab-proof: the gesture falls back to a pan and nothing is focused; a pinned widget too, and nothing beneath it is reached | state `swipe_move`: the same [screen-space drag](#dragging-a-pinned-window) is installed, then the window is raised and focused, as upstream's `GestureTarget::Pinned` arm does |
| a resize gesture | falls back to a pan | the gated `swipe_resize` of any window |
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

`begin_drag` on a screen-pinned window installs upstream's pinned move grab
(`start_pinned_move`, `MoveGrab::new_pinned`). The move gesture installs the
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
  installed, pinned or not. No command sequence makes a pinned window owe
  one, since a pin waits for the transaction and no size is ever asked of a
  pinned window, so that guard has nothing to refuse here.
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
- `begin_drag` raises and focuses nothing, for a pinned window as for a canvas
  one. Upstream's `try_pinned_button` raises and focuses the window before the
  grab; that is the press path's, not the drag's. The move gesture does raise
  and focus it, after the drag is installed, as upstream's does.

### What resizing one would need

Not implemented: native resize is gated, and `begin_resize` and
`begin_native_resize` refuse a pinned window with `a screen-pinned window is
not moved or resized by hand`. Upstream's `apply_pinned_resize`
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
(`docs/config.md`). A Mac has no layer surfaces, and every window here is a
regular one, so this port ignores it as upstream does: the window's `rule`
lists the value, `rule.not_applied` names `layer_order`, and `placements`,
`hit`, `input` and `focus-center` are in stacking order within each bucket
whatever a rule says.

## Wire contract

One command is new, and the shell must send it:

| `command.op` | Fields | Result |
| --- | --- | --- |
| `outputs_settled` | none | `{dirty}`: true when a pin moved to another output |

The shell answers every screen change, and Return to desktop followed by Open
canvas, by removing all its outputs and registering the current ones again.
`outputs_settled` after the last `register_output` is the first moment the
controller can tell a display that is gone from one that came straight back.
Without it a pin whose display is gone stays undrawn until a discovery pass
ends.

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
| `attach` of a new window | `transaction`, `effects` | only when the window's rule names a `size` and a size transaction began for it: the transaction's id, and its effect as the one entry of `effects` ([A rule's `size`](#a-rules-size)) |
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
- **A pin is saved with its slot**, in the additive field `pins`
  (`{"<window>":{"output":ID,"screen_pos":[x,y]}}`), omitted while empty, so
  an older build still reads a save that has none. The slot's saved frame is
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
- **`size` is gated, and asked after the placement.** Upstream configures the
  client to the rule's size first and places it on the follow-up commit, a
  widget and a rule-pinned window included. Here the window is placed at its
  own size and then asked ([A rule's `size`](#a-rules-size)), so the frame is
  centered for the size asked and a window that grants less keeps that
  top-left, as IPC `resize` does, where upstream centers the size it got; an
  odd difference halves toward zero, which can put the frame one pixel from
  where upstream's would be. Without `--experimental-native-resize`, for a
  widget and for a screen-pinned window nothing is asked at all, and
  `rule.not_applied` names `size`.
- **`fullscreen` is recorded, not applied**, and named in `not_applied`.
- **`preserve_aspect_ratio`** is recorded and listed in `not_applied`: no
  resize is bent to it.
- **`layer_order` is ignored, which is upstream's own rule for a window.**
  It is listed in `not_applied` because the field does nothing here, not
  because something is missing: upstream applies it to layer-shell surfaces
  only (`docs/config.md`: "Ignored for regular windows"), and there are none
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
- **No fullscreen legs.** Upstream's fullscreen window claims in its own
  branch of each site, and is the subject of a notch on its output. Nothing
  is fullscreen here.
- **A pinned window is not resized, and not moved by a title bar.** Upstream's
  `try_pinned_button` raises and focuses a pinned window and starts
  `start_pinned_move` or `start_compositor_resize_with_edge`; its title bar,
  a client move request and the move and resize gestures do the same. Here
  the move binding's drag and the move gesture's are adapted
  ([Dragging a pinned window](#dragging-a-pinned-window)). The resize is
  refused: the shell reads `pinned` from the hit, starts no gesture,
  withholds the press and says why in its status line, and a resize gesture
  over one is the gated `swipe_resize` of any window. There is no compositor
  title bar to drag, and a bound press's drag neither raises nor focuses the
  window, where upstream's does both first. So of upstream's way to find a
  rule's numbers (pin, drag and resize into place, copy `position` and
  `size` from `msg state`) the drag and `position` work and the resize does
  not. On a widget the shell starts no gesture, says why, and passes the
  press on to the widget's application as a plain click, as upstream's move
  and resize arms fall through to click-to-focus.
- **A pinned drag's pointer is held in arithmetic, not on the screen.**
  Upstream confines the cursor itself to an output, and that is all that
  bounds its pinned move. macOS owns the cursor here: it goes into the
  toolbar strip and out of a windowed panel, and the controller takes it as
  held at the edge of the drag's output. After an overshoot the cursor has to
  travel back to that edge before the frame leaves it, where upstream's moves
  at once: upstream clamps each relative motion, so its cursor never
  accumulates an overshoot, and a report here is an absolute position. A move
  gesture's pointer is the controller's own and is held as upstream's is.
- **Pins leave a removed output only at `outputs_settled`.** Upstream rehomes
  a pin the moment its output is unplugged. The macOS shell learns of a
  screen change as one notification and answers it, like Return to desktop,
  by removing every output and registering the current ones, so a removal by
  itself says nothing about which display is gone. The controller therefore
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

[`tests/rules_flow.rs`](tests/rules_flow.rs) drives every scenario through the
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
and focuses it, the resize is the gated one) and over a canvas window, and a
move gesture whose slot is adopted as a widget; an open cycle and a coast ended by
`toggle-pin-to-screen` and by `move-to-bookmark`, and both run from a hot
corner;
a rule's `size` without the capability and with it (asked, answered, and not
asked of a second window while the first is owed, of a window that has the
size already, of a widget, of a rule-pinned window and of an adopted slot);
a close with only a widget or a pinned window left in view, and the close of
a pinned window or a widget lying over a canvas window; a detached slot under
a drag adopted as a widget; output removal with and without a settle, and the
shell's own order for a screen change (remove both, register both or one,
`outputs_settled`), with a display that returns smaller; the save file and
two next launches. Expected rectangles are derived by hand from upstream's
conventions. The `hover` and pick-mode rows of the table above are driven by
[`tests/pointer_flow.rs`](tests/pointer_flow.rs)
([POINTER.md](POINTER.md#evidence-and-limits)), the same way, and the sizing
rows by [`tests/sizes_flow.rs`](tests/sizes_flow.rs)
([SIZES.md](SIZES.md#verification-boundary)). In the `size` scenario the test
plays the shell's part and answers the resize effects itself: no native window
was resized, by a rule or otherwise.

[`tests/passthrough_flow.rs`](tests/passthrough_flow.rs) does the same for
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
dragged there, and every claim back at zoom 1. Its fullscreen and title-bar
cases have nothing to run against here. A pinned window is dragged at zoom
0.5 on an output that is not at the global origin: by the screen
displacement and not by twice it, a half rounded, unclamped past two
corners, with the pointer in the edge-pan zone against a canvas window's
control, saved and loaded, and unpinned; across to the other output and
back; with the pointer on no output, above the output and past its far
corner, and in the 64-point strip above an output laid out as the shell's
is, where the frame stays drawn and hit; against every other gesture, a
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
[what was run once the two were built together](#with-the-shell-pass-rules-and-the-pinned-drag-2026-10-10)
reached none of it. Nothing here
shows that a native window is drawn at an opacity, blurred, kept above
another, or receives a click; that a real application's bundle identifier or
title matches a rule; or what a real display reconfiguration does. The order
the tests replay (every output removed, the current ones registered, then
`outputs_settled`) is the one `native/desktop/main.m` sends from
`screensChanged`, `cleanup` and `openPanels`, read there and not observed with
a second display. The shell's use of `opacity`, `widget` and `pinned` is its
own to verify; [what was run for it](#with-the-renderer-2026-10-10) is below.
Upstream's behaviour was read from the files named above, not run.

One more scenario in the same file crosses this contract with
[RENDER.md](RENDER.md#verification-boundary): a widget, a rule-pinned window
and a canvas window described for one frame, with the layer keys, the pinned
`screen_rect` against the camera, one opacity in `opacity` and
`decoration.opacity`, and what a `Window` and an `All` capture take of them.

### Live run, 2026-10-10

The built app (`scripts/build-app.sh`, ad-hoc signed, macOS 27.2, Apple
Silicon) was launched once as `--windowed 1100x700` on a private scene, config
and socket and driven through `Infinify msg` for six seconds. It repeats, on
the build with the review fixes, a first run of 2026-10-09. It had no Screen
Recording access, so it managed no window, sent no `adoption_complete`, and
every window was a placeholder. Nothing from the run is saved as evidence.

The scene was written by a throwaway program driving this controller in
process: three synthetic sources and two outputs, `windowed` and `away`. The
third window was pinned on `away` with a `Pin` write, at the output-local point
(100, 100). The second was moved 60 right of and 10 above `windowed`'s view
center, pinned with `toggle-pin-to-screen`, unpinned, and pinned again by a
`Pin` write before the save. That program, not the app, is where a live window
was pinned: `State.pinned` read `[60, 10]` before and after `pan-viewport
right`, the unpinned frame's center read `2110 10` against `2010 10` before the
pin (the camera had moved 100), `Pin` writes of `true` and `false` answered
themselves, and `Opacity` read 1, took 0.5, read 0.5 and refused 1.5.

Observed in the app, over the socket:

- Both pins loaded from `pins`. The app registered `windowed` and never
  `away`, and its first `state` listed window 3 under `pinned` on `windowed`
  at `[-170, 28]`, 560x380, which is the point (100, 100) on a 1100x636
  output. No discovery pass ran, so it was the shell's `outputs_settled` that
  moved it. Window 2 was listed on `windowed` at `[60, 10]`, 900x600, and
  window 1 under `windows`. The file saved at exit held window 3's pin on
  output 1 at `[100, 100]`.
- Neither entry changed with `pan-viewport right`, nor with a
  `toggle-pin-to-screen` or a `move-to-bookmark` while window 2 held the
  focus. A `Move` read of each, the canvas frame re-anchored after each
  command, followed the camera: `610 -308` and `380 -290` before the pan,
  `710 -308` and `480 -290` after it. The canvas slot read `520 -360` both
  times.
- `Move` and `Resize` writes on window 2 answered the two refusals quoted
  under [IPC](#ipc); a `Resize` read answered `900 600`.
- `Pin`, read or write, on each placeholder: `stand-ins can't be pinned`.
  `Opacity`, read or write: `no window with id N`. `toggle-pin-to-screen`
  with a placeholder focused, pinned or not: Ok, nothing changed.
- Two rules in the config matched placeholder titles, one with `widget`, one
  with `pinned_to_screen` and a `position`. Nothing mapped, so nothing was
  resolved: `is_widget` stayed false, and window 3 stayed where its saved pin
  put it, not at the rule's position.
- `move-to-bookmark` centered a focused placeholder on the bookmark (`Move`
  read `300 200`), and did nothing for an unset name or with the pinned
  placeholder focused.
- `decoration = "fancy"` gave upstream's warning at launch; a rule key the
  grammar lacks gave upstream's TOML `unknown field` error on reload, and the
  app went on answering.
- SIGTERM: exit status 0, socket removed.

Not observed in the app: a rule resolved at `attach`, a widget, a pin or unpin
of a live window, an `Opacity` write, the close of any window (so none of the
focus-follow rules), a pinned window adopted at launch or turned into a
stand-in, a screen change or Return to desktop with a pin in place, a zoom
(the first run read the pinned entry unchanged at zoom 0.5), a pointer press
(so neither status note, nor a click forwarded to a widget), `hit` and `input`
on any of them, and everything drawn: the order of the tiles and their opacity
were not looked at.

### With the renderer, 2026-10-10

The same day this contract and [RENDER.md](RENDER.md) became one build, and
what a window's `widget`, `pinned` and `opacity` do to the picture was run
twice. Nothing from either is saved as evidence; the numbers are in
[native/desktop/README.md](../../native/desktop/README.md#what-was-run-for-rules-and-rendering-together).

- A throwaway tool outside the repository linked the shell's renderer and the
  compositor against this controller, gave it a ruled widget, a rule-pinned
  window and an ordinary window with synthetic sources on an output whose
  origin is not the global origin, and read each frame back from the output's
  compositor layer. The pinned window kept its output-local rectangle and its
  own size at zoom 0.5, after a pan and at zoom 1, above the canvas window;
  the widget showed only where the canvas window did not cover it; an
  `Opacity` write of 0.5 blended the canvas window and the pinned one over
  what lay beneath; the pinned window's detached slot was an opaque stand-in
  at the same rectangle.
- The built app, `--windowed 1100x700` on a private scene, config and socket
  for one second, with no Screen Recording access, read a scene whose `pins`
  held one placeholder at the output-local point (500, 200), pinned by a
  throwaway program driving this controller. `state` listed it under `pinned`
  at `[230, -72]`, 560x380, before and after `pan-viewport right` and at zoom
  0.5, while its `Move` read went from `780 -390` to `880 -390` to `830 -272`.
  None of the three viewport screenshots held it, a `window` screenshot held
  it alone, and `all` framed the other two placeholders. `Pin` and `Opacity`
  answered `stand-ins can't be pinned` and `no window with id N`, `Move` and
  `Resize` writes the two refusals above, and the file saved at exit held the
  pin unchanged.

Still not observed in the app: its own panel on a display, so a pinned
placeholder drawn over a canvas one there; a rule resolved at `attach`, a
widget, a live window pinned or given an opacity; a pointer press.

### With window navigation, motion and gestures, 2026-10-10

The same day this contract was joined to the controller's later work: window
navigation and `activate`, the one focus history, hot corners, `send-to-output`,
the event stream, camera motion and trackpad gestures.
[Navigation, activation, gestures and outputs](#navigation-activation-gestures-and-outputs)
is what the join decided, and four scenarios at the end of `tests/rules_flow.rs`
are its coverage. The earlier scenarios were restated for the one history:
where they read a second, logical history they now answer the pending focus
request `focus_logical`, as a shell that performs no native focus does.

The built app was launched three times on a private scene, config and socket
([the numbers](../../native/desktop/README.md#what-was-run-with-every-other-milestone-built-in)),
again with no Screen Recording access and placeholders only. Of this contract
it observed: a placeholder pinned in the scene file under `State.pinned`
through a pan and a zoom, and in every line of a `subscribe` stream; the same
`Pin`, `Opacity`, `Move` and `Resize` refusals; `toggle-pin-to-screen` leaving
a focused placeholder alone and `move-to-bookmark` moving one; and, with the
pinned placeholder focused, `center-nearest` and `center-window` choosing a
canvas placeholder. The table's other rows were not observed in the app: no
window was live, no widget existed, and no key, pointer press, gesture, hot
corner or second display was involved.

### With the shell: pass rules and the pinned drag, 2026-10-10

The controller of [Pass rules](#pass-rules) and
[Dragging a pinned window](#dragging-a-pinned-window) and the shell's use of
it were written apart and built together the same day. The boundary was
checked by reading both sides:

| The shell | The controller |
| --- | --- |
| reads `snapshot.pass_keys` in its one redraw (`-[Desktop render]`), which every applied reply and every focus report ends in, and hands it to its hot keys | emits `null`, `true` or a list of `combo` strings |
| keeps `passable` from each entry of `bindings.keys`, absent meaning false, and never unregisters the exit chord or a `quit` whatever it says | emits `passable` on every key and media-key entry |
| matches a passed combo to a hot key by the text of `bindings.keys[].combo` | spells a pass list's combo with the function that spells `combo` |
| sends `mouse_binding` with `window` for a press and for a scroll over a hit the controller reported, never for a placeholder's hit, which it builds itself; reads only `binding` | takes an optional `window`; a claim answers `{"binding":null,"passed":true}` |
| sends `begin_drag` for a move binding on a pinned hit, with `group` a real boolean, then the `gesture_to` (with `pointer`) and `end_gesture` of any drag | installs the pinned drag; ignores `group` |

That reading found no defect at the boundary and changed neither side. A
review the same day found one: the shell reports a drag's pointer wherever
macOS has it, the toolbar strip above its output and the space around a
windowed panel included, where upstream's cursor never leaves an output, and
a pinned frame could be let go wholly off its output, undrawn and out of the
pointer's reach. The controller now holds such a pointer at the edge of the
drag's output ([Dragging a pinned window](#dragging-a-pinned-window)); the
shell is unchanged. What
the shell does with each is in
[native/desktop/README.md](../../native/desktop/README.md#passing-keys-and-presses-to-an-application).
Two things the shell does not do: it reads no media key entry, so their
`passable` is unused; and its press path sends no `focus` or `activate`
before `begin_drag`, so a pinned window dragged by a bound press is not
raised or focused. On that day's build it asked no `wheel_up` or
`wheel_down` lookup either, and the controller ranked windows by
`layer_order`; [the merge below](#merged-with-the-pointer-policy-window-sizing-and-effects-2026-10-10)
changed both.

The eight test modules named above for this contract's commands passed on that
build, and again after the review fixes of the same day, which added two
scenarios to the first (`passthrough_flow` 16, `rules_flow` 21, `config_flow`
12, `gesture_flow` 21, `navigation_actions_flow` 12, `lifecycle_flow` 25,
`ipc_flow` 8, `controller_flow` 4). Those fixes were the controller's alone:
the pointer of a pinned drag held on an output, a pinned slot keeping its
drag through its adoption, and a pinned drag ending when a discovery pass
keeps its slot as a stand-in.

The built app was launched once, `--windowed 1100x700`, on a private scene,
config and socket, with no Screen Recording access and so with placeholders
only ([the numbers](../../native/desktop/README.md#what-was-run-for-the-pass-rules-and-the-pinned-drag)),
and once more, for three seconds and to the same observations, on the build
with the review fixes.
Of this contract it observed: a config with `pass_keys = true`, `pass_mouse =
["alt+left"]` and `layer_order` in one rule, and a `pass_keys` list,
`pass_mouse = true` and a negative `layer_order` in another, loading and
reloading with no warning; upstream's `config: pass_keys invalid key combo …`
and `config: pass_mouse invalid mouse combo …` warnings for a combo the grammar
lacks, with the app answering afterwards; and a placeholder pinned in the scene
file listed under `State.pinned` before and after a pan. A throwaway program
read the same scene and config through this controller in process:
`snapshot.pass_keys` was `null` with each placeholder focused, and
`mouse_binding` naming each as `window` answered the binding, not `passed`,
which is the rule of [`pass_keys`](#pass_keys) and [`pass_mouse`](#pass_mouse)
for a window without a client.

Not observed anywhere but in `tests/passthrough_flow.rs`: a non-null
`pass_keys`, a `passed` reply, a pinned drag. Not observed
at all: a hot key leaving or returning, a key, press or scroll reaching an
application, a pointer moving a pinned window. The windowed launch registers
no hot keys, the IPC surface has no verb for a drag or a binding lookup, and
no window had a client.

### Merged with the pointer policy, window sizing and effects, 2026-10-10

The pass rules and the pinned drag were written on a tree that had neither
pick mode, hover focus, the sizing actions nor the lifecycle events. Joined to
them the same day, this is what the join decided:

| Where the two met | Decided |
| --- | --- |
| `mouse_binding` has two optional arguments, `window` and `pick` | one lookup: a pick target claims nothing, a screen-pinned window keeps its button claims below `[zoom] interact_min` and loses its scroll and notch claims there ([`pass_mouse`](#pass_mouse)). Upstream's gate, which the pass rules could not have without a pick mode |
| `install_drag` holds the widget refusal, the pinned drag, the owed-size guard and pick mode's drag-anywhere | in that order of asking: a widget is refused, a window owed its size is refused, a pinned window is then dragged in screen space, at any zoom ([Dragging a pinned window](#dragging-a-pinned-window)) |
| hover focus moves the focus without a raise, by a request that may be answered late or never | `pass_keys` already asks who holds the keyboard, so nothing changed in the rule: scenarios now show it through a hover's answer, echo, failure, withdrawal and expiry ([`pass_keys`](#pass_keys)) |
| the shell applies replies in one place, which now also consumes a size transaction and carries the hover | the comparison of `pass_keys` stays in the one redraw every applied reply ends in, a hover's and a pointer command's included. No poll |
| a close under a pinned drag, with lifecycle events | one `close` or `close_to_standin`, as for any window |

Three things were corrected in the same pass, each from upstream's source:

- **`layer_order` orders nothing again.** The first build ranked the windows
  of one bucket by it. Upstream applies it to layer-shell surfaces only and
  documents it as ignored for regular windows, so the ranking was removed:
  the field is read, shown and named in `not_applied`
  ([`layer_order`](#layer_order)).
- **The shell asks the wheel notch.** For each event of a discrete wheel it
  now looks `wheel_up` or `wheel_down` up first, where upstream's notch site
  stands ahead of its continuous lookup, runs an action binding, and
  otherwise falls through, a passed notch included.
- **The move gesture moves a pinned window.** It was claimed and inert
  (`swipe_pinned`, with a note). Upstream's `try_start_gesture_move` installs
  the pinned move grab for a pinned target and raises and focuses the
  window, and so does `gesture_begin` now, in state `swipe_move`.

The controller modules passed on the merged build: `passthrough_flow` 19,
`rules_flow` 22, `pointer_flow` 16, `sizes_flow` 30, `effects_flow` 5,
`render_flow` 7, `gesture_flow` 21, `motion_flow` 9, `platform_actions_flow`
11, `navigation_actions_flow` 12, `lifecycle_flow` 25, `config_flow` 12,
`ipc_flow` 8, `controller_flow` 4, `navigation_flow` 5 and `focus_cycle_flow`
5. Five scenarios of the other contracts changed with the join: one of
`pointer_flow` and one of `sizes_flow` asserted that `begin_drag` refuses a
pinned window and now assert its screen-space drag, above and below the
threshold; one of `sizes_flow` and one of `render_flow` listed a reply's
exact keys and now list `passable` and `pass_keys`; and the gesture scenario
of `rules_flow` asserts the move where it asserted `swipe_pinned`.

The built app was launched twice, `--windowed 1100x700`, on a private scene,
config and socket, with no Screen Recording access and so with placeholders
only ([the numbers](../../native/desktop/README.md#what-was-run-for-the-pass-rules-with-everything-else-built-in)).
Of this contract it observed: a config with `pass_keys = true`, `pass_mouse =
["alt+left"]` and `layer_order = 2` in one rule, and `"mod+wheel-up" =
"zoom-in"` in `[mouse.anywhere]`, loading and reloading with no warning;
upstream's two warnings for a combo the grammar lacks; and a pin listed
under `State.pinned`, before and after a pan, at the place a throwaway
program had dragged it to through this controller's `begin_drag`,
`gesture_to` and `end_gesture` before saving the scene. The same program
read the scene and the config in process: no window had a source or a
`rule`, `pass_keys` was `null` with each focused, `mouse_binding` naming
each as `window` answered the binding, and `wheel_up` under ⌃⌥ answered
the `zoom-in` action in both contexts.

Not observed anywhere but in the controller scenarios: a non-null
`pass_keys`, a `passed` reply, the pick-mode gate, a pinned drag by pointer
or by gesture in a running shell. Not observed at all: a hot key leaving or
returning, a key, press, scroll or wheel notch reaching an application or
running an action, a hover changing what is passed, a swipe moving a pinned
window. The windowed launches register no hot keys, the IPC surface has no
verb for a press, a scroll, a hover or a gesture, and no window had a client.
