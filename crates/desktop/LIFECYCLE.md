# Window lifecycle, ABI 1

In DriftWM every toplevel is managed: it is placed when it maps, it leaves when
it is destroyed, and a stand-in can stay behind for it. This is that contract
for the controller. A window that appears is adopted into a waiting slot or
placed by `window_placement`; a window that closes leaves the scene or leaves a
stand-in; titles follow; closing, suspending and relaunching are actions.

The rules are adapted from malbiruk/driftwm at
`352333a8fa1b22171492d4b71a54102045c9a19d`: `src/state/placement.rs`, the first
sized commit in `src/handlers/compositor.rs`, `toplevel_destroyed` in
`src/handlers/xdg_shell.rs`, `src/state/suspended.rs`, the follow helpers of
`src/state/navigation.rs` and the `Close`, `Suspend` and `Relaunch` arms of
`src/ipc/mod.rs`. The placement search is `driftwm-core`'s
`layout::auto_placement::place_auto`, upstream's own code; so are
`layout::cluster::cluster_of` and the window-rule matcher.

One existing command gains two optional inputs and three commands are new.
`ABI_VERSION`, `SAVE_VERSION` and every other command shape are unchanged; the
snapshot gains `lifecycle`. The controller still
performs no native operation: `close_window`, `launch` and
`focus_native_window` are requests to the shell.

| `command.op` | Fields | Result data |
| --- | --- | --- |
| `attach`, a new window | as before, with neither `logical_id` nor `world_rect`; optional `output`, optional `pointer` | `{window, adopted, effect, navigation, dirty}`, and `transaction` with a one-entry `effects` when a size transaction began with this map, for the `size` this window's rule names or for that of a window that was waiting its turn ([RULES.md](RULES.md#a-rules-size)) |
| `window_closed` | `window`, `identity`, optional `output` | `{standin, effect, navigation, dirty}` |
| `retitle` | `window`, `identity`, `title` | `{dirty}` |
| `adoption_complete` | optional `present`, an array of `{bundle_id, title}` | `{dropped, standins, dirty}` |

`effect` is a `focus_native_window` request exactly as [`focus`](FOCUS.md)
returns it, or `null`. `navigation` is the armed flight
`{output,generation,target_camera,target_zoom,animating}` exactly as
[`navigate_window`](NAVIGATION.md) returns it, or `null`; schedule frames while
it is an object. `dirty` is true when saved state changed.

## Three kinds of window

- A **live** window has a bound source.
- A **stand-in** is upstream's suspended window: a detached placeholder that
  stands for a window that is gone. It keeps the logical id, the world frame
  and the place in the stack. It is dormant: nothing takes it over until it is
  relaunched. `snapshot.lifecycle.standins` lists them and the scene file saves
  the list.
- A **waiting slot** is a detached placeholder that is no stand-in: a slot whose
  own window is expected back. These exist after `load` (every window that was
  open at the save) and after `remove_source` with `keep_placeholder` (a lost
  capture, or the shell detaching its sources). The next
  [`adoption_complete`](#slots-and-re-adoption-the-macos-rule) decides each one
  that is still waiting.

All three are one `suspended: true` in the IPC `State` and one "detached
placeholder" everywhere else in this ABI, as before.

Which of the events below upstream animates, and how the snapshot's
`lifecycle_events` reports each to the shell, is
[EFFECTS.md](EFFECTS.md#lifecycle-events).

## A window appears

`attach` with neither `logical_id` nor `world_rect` means a window appeared by
itself. `output` is the active output and `pointer` the pointer as a global
screen point; both are optional and both are checked when given. `source_rect`
contributes its **size** only: no world position ever derives from where the
native window sits on the desktop.

`attach` with a `logical_id` or a `world_rect` is exactly what it was: the
caller names the slot or the frame, the reply is `{"window":id}`, nothing is
focused, and `output` and `pointer` are not read.

### 1. Adoption

A new window with a non-empty bundle identifier takes over a detached slot of
the same bundle identifier, in this order:

1. Upstream's identity match: the oldest pending relaunch of that app. Order is
   the order the relaunches were asked for, as upstream's is spawn order. A
   relaunch is pending for thirty seconds.
2. A waiting slot of that app with the window's title.
3. The waiting slot of that app with the lowest logical id, among those not
   *held*: a slot the last `adoption_complete` kept for a window that exists
   off screen answers to its own title only.

A dormant stand-in is never taken, and a window without a bundle identifier
adopts nothing. The adopted window keeps the slot's logical id, world frame and
place in the stack, whatever its native size is; its title replaces the slot's.
As in upstream's `adopt_relaunched` the camera does not move and nothing is
raised. The window takes the focus, with a focus effect, only when the slot was
the focused window.

Steps 2 and 3 are the macOS rule described under
[Slots and re-adoption](#slots-and-re-adoption-the-macos-rule); upstream has
neither.

### 2. Placement

Otherwise a window rule's `pinned_to_screen` or `position` places it, as
[RULES.md](RULES.md#a-new-window) describes, and nothing below applies.
Without either, `window_placement` places it. All arithmetic is upstream's: the
frame's size is rounded to whole points for the policy, positions are rounded,
and halving a size truncates. Chrome is zero, because a native frame already
includes its title bar.

- `center`, the default: under the active output's `focus_placement` point, the
  usable center unless the config moves it. The point is taken at the zoom the
  navigation lands at and converted through the current camera and zoom.
- `cursor`: centered on the pointer, read through the active output's own
  bounds and camera, and held inside the usable area; an oversized frame keeps
  its top-left on the usable edge. Without a `pointer` this is `center`.
- `auto`: `place_auto` beside the cluster of the focused window while at least
  a third of it is in the output's view, else of the element nearest the usable
  center, the topmost of equally near ones. Detached placeholders anchor like
  windows and every window is an obstacle. With nothing in view, or no free
  slot, this is `center`.

Then upstream's cascade, for all three: while the spot is within two points of
another window's top-left on both axes it moves down the diagonal by
`[decorations] title_bar_height` (25). A window still owed the `size` its
rule names counts, here and as an obstacle of `auto`, as the frame it is
becoming ([RULES.md](RULES.md#a-rules-size)).

Without an `output` upstream has no view to place in: the origin, cascading.

### 3. Mapped

A placed window goes on top of the stack. Then, as at upstream's first sized
commit:

- it is focused, with a focus effect;
- the camera navigates to it, to zoom 1 with `zoom.reset_on_new_window` (the
  default) and at the current zoom without;
- except under `cursor` placement, which stays put: raised and focused only,
  unless the reset is on and the output is zoomed out, upstream's overview
  rescue.

No flight is armed during a drag or resize gesture. Without an `output` there
is no view to reveal it in: the window is placed at the origin, on top, and is
neither focused nor navigated to. During the
[launch pass](#slots-and-re-adoption-the-macos-rule) a placed window is neither
focused nor navigated to. Nor is a widget, or a window whose rule says
`focus_on_open = false`; a window pinned by its rule is focused and not
navigated to.

## A window closes

`window_closed` reports that the native window is gone. `identity` must be the
bound one. `output` is the active output; without it the home output is used,
the one whose view contains the window's center, else the first.

Upstream's `toplevel_destroyed` decides what is left:

1. A mark decides first. `close-window` and IPC `Close` mark a real close;
   `suspend-window` and IPC `Suspend` mark a suspend. The later of two wins. A
   mark lapses ten seconds after its command, as upstream's does: an
   application that refused to close is then an ordinary survivor.
2. With no mark, `session.suspend_on_close` decides, as it resolves for the
   window: a `[[window_rules]]` entry's `suspend_on_close` whose `app_id`
   matches the bundle identifier, or `title` the title, overrides the section.
   A window without a bundle identifier could not be relaunched and never
   leaves a stand-in.

**A stand-in stays** (`standin: true`): the source is gone, the window keeps
its id, frame and place in the stack, and it keeps the focus if it had it. It
drops out of the focus history. Nothing else is refocused.

**The window leaves** (`standin: false`): it is removed from the scene, and
focus follows as upstream's does. Focus moves only when the window held it, or
when nothing was focused; any other focused window, a detached placeholder
included, keeps the focus through the close. The follower is, in order:

1. the most recent window of the focus history that is in the closed
   frame's snap cluster or overlaps it. Wholly inside the usable area it is
   raised and focused. Otherwise, with `navigation.auto_navigate_on_close`
   (the default) the camera flies to it at the current zoom; without, it is
   not a candidate. A widget or a screen-pinned window that closes has no
   snap rectangle, so nothing is spatially related to it: its follower is
   looked for from step 2;
2. the most recent window of that history that is at least partly visible on
   the home output;
3. the live canvas window nearest the closed frame's center among those partly
   visible there (never a widget or a screen-pinned window);
4. nobody: nothing is focused, rather than a window nobody can see.

A widget and a screen-pinned window are never in the focus history, so
neither is ever the follower: closing the last canvas window in view leaves
nothing focused even with a widget or a pinned window on screen
([RULES.md](RULES.md)).

The **focus history** is the one the [focus cycle](FOCUS.md) walks:
`snapshot.focus.history`, live windows in the order their focus was last
settled, most recent first. Upstream has one history, filled by every focus
change, for `cycle-windows` and for these tiers alike, and so does this
controller. Every way a window takes the focus here returns the same focus
request: `focus`, IPC `Focus`, `activate`, the window navigation actions, a new
window that was revealed, the follower of a close and IPC `Suspend`. The window
enters the history when that request is answered, `focus_result` with success
or `focus_logical` from a shell that performs no native focus; `observe_focus`
and `activate` with cause `native` enter it directly, and a committed cycle
promotes its selection alone, the steps it passed staying where they were. So
the tiers need no report of native focus, only an answer: a request nobody
answers enters nothing, and a host that answers none leaves the first two tiers
empty. A window adopted during the launch pass into the slot that held the
focus enters at once, because no request is made for it and so none can be
answered. A detached placeholder is never in it, and it is not saved. A widget
and a screen-pinned window take the focus in every one of these ways and enter
by none of them; a window leaves the history when it is pinned, and a focused
one whose focus was settled returns to its head when it is unpinned.

A drag or resize gesture in progress ends only when the window that closes, or
is replaced by a stand-in, is one the gesture captured: the dragged or resized
window, or a member of its group. Upstream ends no other window's grab. A drag
that ends this way ends as a release ends it: the
[edge pan](MOTION.md#edge-pan-while-a-window-is-dragged) it had armed is
disarmed, and a [trackpad move](GESTURES.md#dispatch) that had installed it
goes on with nothing to move. While a
gesture goes on no flight is armed for the follower; it is focused all the
same.

`remove_source` is unchanged and remains the report for a source that was lost
while its window is still there: with `keep_placeholder` it leaves a waiting
slot, not a stand-in.

## Titles

`retitle` replaces the saved title of a bound window. `dirty` is false when the
title was already that. Titles matter beyond display: a waiting slot is matched
to its window by title. A new title does not re-apply window rules: upstream
resolves them once, when the window maps.

## Actions and IPC

| Entry | Focused or selected window is live | It is a detached placeholder |
| --- | --- | --- |
| `close-window`, `{"Close":sel}` | effect `close_window`; marked a real close | dismissed |
| `suspend-window` | effect `close_window`; marked a suspend, or a real close when it has no bundle identifier | dismissed, upstream's second press |
| `{"Suspend":sel}` | focused first if it is not, without moving the camera (a focus effect, `dirty`), then as the action | `Err("window is already suspended")` |
| `{"Relaunch":sel}` | `Err("no suspended window matching selector")` | effect `launch`; a relaunch is pending for thirty seconds. While one is pending: `Ok` and no effect, upstream's no-op |

The effects, in the `effects` array of the `action` and `ipc` replies:

```json
{"op":"close_window","window":3,"identity":{…},"generation":7}
{"op":"launch","bundle_id":"com.apple.Terminal","window":3}
```

`close_window` names one binding: the shell must validate that identity afresh
and press that window's own close button. The controller issues it only from
these four entries, never by itself, and removes nothing until `window_closed`
arrives: an application that refuses to close keeps its window. `launch` asks
the shell to open the application; `window` is the stand-in it is for.

Selectors are upstream's two tiers. `Close` and `Suspend` look among live
windows first (`no focused window`, `no window with id N`,
`no window matching 'text'`), then among detached ones; `Relaunch` looks among
detached ones only. No selector is the focused window.

Dismissing a detached placeholder removes it, cancels its pending relaunch and
moves the focus through the same tiers as a close, less the first condition: a
dismissed placeholder passes the focus on only if it held it.

`snapshot.lifecycle` is `{settled, standins, relaunching, marks}`: whether the
launch pass is over, the stand-ins, the pending relaunches oldest first, and
the marks by logical id (`"close"` or `"suspend"`). A mark needs a bound window
and a pending relaunch a detached one; both are dropped when that stops being
true, and when they [lapse](#differences-from-upstream). `held`, the logical
ids of the waiting slots kept for windows that exist off screen, is present
only while there is one.

Upstream relaunches a focused stand-in on Enter and on a click on its name.
Neither is a config binding, so neither is in the `bindings` reply. The entry
point for both is `{"Relaunch":null}` through the `ipc` command; delivering the
key or the click is the shell's, and the app's shell delivers neither yet.

## Slots and re-adoption: the macOS rule

On Wayland, quitting the compositor ends its clients. Upstream's session file
therefore holds stand-ins only: every restored window is one, and what
`session.restore_windows` decides is whether a window that was merely open at
the last save is written at all.

On macOS applications outlive Infinify. So:

- **The scene file keeps a slot for every window**, live or not, as it always
  has. The additive key `standins` lists the logical ids that are stand-ins; it
  is omitted while empty, and a file without it has none. Nothing else changed
  in the file: no pid, window number, process birth or binding generation is
  written.
- **The launch pass.** Until the first `adoption_complete`, the windows the
  shell reports are the ones that were already open. Each takes its waiting
  slot back by the adoption rule above, or is placed. None is focused or
  navigated to and no focus effect is issued: nobody opened them just now, and
  stealing native focus at launch would be the canvas's doing alone. The saved
  focus stays on its slot.
- **`adoption_complete`** ends a discovery pass. The shell sends it after the
  first read of its window list at launch, and again after the first read of a
  canvas that reopened. A waiting slot that is still waiting belongs to a
  window that closed while nobody was looking. With `session.restore_windows`,
  as it resolves for the slot, it becomes a dormant stand-in, exactly what
  upstream restores for a window that was open at the last save. A window
  rule's `restore_windows` overrides the section, and is asked twice as
  upstream asks it: with the title, where upstream decides whether to record
  the window, and by app alone, where upstream restores it; both must hold, so
  a rule keyed on a title alone restores nothing. Without, the slot is dropped;
  if it was the focused window nothing is focused. Slots without a bundle
  identifier are dropped either way. Stand-ins are never dropped: upstream
  always restores them. The reply lists both groups by id. With nothing
  waiting it changes nothing. Only the first one ends the launch pass. A
  waiting slot is decided even while a relaunch is pending for it: if its
  window has not appeared by then and the slot is dropped, the relaunch goes
  with it and the window is placed as a new one when it comes; kept as a
  stand-in, it keeps its relaunch.
- **`present`** names the windows that still exist but could not be offered:
  minimized, hidden, on another Space. They never closed, so their slots are
  neither dropped nor made stand-ins. For each entry with a bundle identifier
  the first waiting slot with that bundle identifier and that exact title is
  *held*: it keeps waiting, and only a window with its own title takes it, so
  a new window of the same app is still placed, focused and revealed. An entry
  that matches no slot is ignored. Each `adoption_complete` says afresh what is
  held: a slot held by the last one and not named by this one is decided like
  any other. No native identity is involved, and `held` is not saved.
- **A config file that was refused.** When the launch config exists but could
  not be read or parsed, the built-in defaults are in force and do not speak
  for the user's `restore_windows`. `adoption_complete` then drops nothing and
  makes no stand-in: it answers `{"dropped":[],"standins":[],"dirty":false}`,
  every slot keeps waiting, and the launch pass is over all the same. The next
  `adoption_complete` after a config was accepted decides, in this run or the
  next. A missing file is the defaults by choice and drops as usual.
- **Between passes**, a window that appears is a new one, and a waiting slot can
  only come from `remove_source`. It still takes its window back by the same
  rule, so a window whose capture failed, or whose source the shell detached
  while the canvas was closed, returns to its own frame, retitled or not.
- **`load` after the launch pass** brings the file's slots but no second launch
  pass: the flag is carried across, as the other counters of a run are. The
  next `adoption_complete` decides those slots.

A shell that never sends `adoption_complete` and never attaches without a world
rectangle sees none of this: the chooser's explicit attach and rebind behave as
they did.

## Differences from upstream

- **Expiry runs on the navigation clock.** Upstream's suspend and real-close
  marks lapse after 10 s and a pending relaunch is dropped after 30 s, by wall
  clock. Here both are measured on the clock `tick_navigation` brings, which
  [NAVIGATION.md](NAVIGATION.md) already tells a host to keep current while
  idle: each is stamped with the clock's reading when the command that set it
  was accepted and lapses once a later reading is that far on. A command that
  replaces a mark starts its own ten seconds. A host that never ticks has no
  clock and sees neither lapse; one set before the first tick, or after a
  `load`, which resets the clock, is stamped by the first tick that follows;
  and a host whose clock stood still when the command came measures from that
  stale reading.
- **The identity match stays open for the whole thirty seconds.** Upstream
  closes it after 5 s and lets the activation token cover a slow launch. There
  is no token here, so identity is the only signal: a pending relaunch takes
  the next window of its app, whatever its title, until it lapses. This is
  upstream's documented capture hazard with a longer window.
- **No activation token.** Upstream's first match signal, the token handed to
  the relaunched process, has no counterpart. Only the identity match exists.
- **Titles and waiting slots in the match**, held slots and every discovery
  pass are the macOS rule above. The pairing is greedy, one window at a time: of two windows
  of one app whose titles both changed, each takes the lowest free slot in the
  order the shell reports them, and a window that kept its title can find its
  slot taken by a retitled sibling reported before it. The same greed is a
  capture hazard like the one upstream documents for its identity match: while
  a slot waits for a window whose capture was lost, a new window of that app
  with another title takes the slot, and the first window is placed afresh when
  it is reported again. Matching by title alone would close that hazard and
  open a worse one, a retitled window orphaning its slot every time the canvas
  is closed and reopened. A held slot is the exception, and its cost is the
  mirror image: a window that was retitled while off screen does not get its
  slot back, and the slot is decided at the next pass.
- **`restore_windows` is read at every `adoption_complete`**, not at save
  time, and it decides whether a slot stays, not whether it was written.
- **Window rules** shape a new window since [RULES.md](RULES.md): `position`,
  `pinned_to_screen`, `output`, `widget` and `focus_on_open` are applied where
  step 2 places it, and a widget is never a stand-in. A rule's `size` is
  asked, and the window placed for it, only under a shell that can deliver a
  size ([RULES.md](RULES.md#a-rules-size)), and its `fullscreen` is applied
  only under one too, after that placement and in place of that request
  ([FULLSCREEN.md](FULLSCREEN.md#a-new-window)).
- **Behind a fullscreen window.** A new window that no rule positions is
  placed in the background of a fullscreen one, and its attach asks for no
  focus; one that macOS makes key all the same ends the fullscreen when the
  shell reports that focus ([FULLSCREEN.md](FULLSCREEN.md#a-new-window)). A
  fullscreen window that closes gives its output its view back first.
- **No parents or modals.** The tiers of upstream that depend on
  them are absent: a child window centered on its parent, the parent as the
  first follower after a close, and the
  dialog exclusion of suspend. A dialog or a sheet
  the shell reports is a window like any other.
- **No blank slate.** Upstream skips auto placement's nearest-element anchor
  after a click on empty canvas cleared the focus (`suppress_auto_anchor`).
  [`clear_focus`](FOCUS.md) clears the focus here without that memory, so the
  anchor is tried after it as in any other unfocused state.
- **A stand-in's frame is the window's current world frame.** Upstream seats a
  marked suspend at the frame recorded when the action fired and reshapes a
  client-decorated body under a title bar; here the world frame is the
  controller's own and is kept as it is.
- **Focus on a restored stand-in** is whatever the scene file saved. Upstream
  applies it only when the stand-in is visible at launch.
- **Relaunch on an empty bundle identifier** answers
  `the app has no bundle identifier to relaunch`, where upstream's `.desktop`
  lookup answers `<name> is no longer installed`. Whether the bundle is
  installed is for the shell to find out when it performs `launch`.
- **`suspended` in the IPC `State`** is true for waiting slots as well as
  stand-ins, as before this contract.
- **Who follows a close.** Upstream also moves the focus when the closed
  window heads the focus history while the keyboard is on a layer surface.
  There are no layer surfaces, so that condition is absent. And on macOS the
  system itself activates another window when one closes: the follower chosen
  here is logical focus plus a request. A shell that reports native focus
  (`activate` with cause `native`, or `observe_focus`) then replaces it with
  what macOS chose; the app's shell does so wherever native focus is allowed,
  and otherwise the follower stands. The tiers read the focus history and share
  its limit: a window whose request failed, or was superseded before it was
  answered, is not in it, where upstream's history would hold it. A window
  adopted during the launch pass enters the history only once its focus is
  settled, so right after launch the first two tiers know only the window that
  held the saved focus.
- **A gesture in progress keeps its camera** when a follower would be flown
  to, as it does when a window appears: no window navigation is armed during
  a drag or resize here. Whether upstream flies during a grab was not read.
- **Scene titles.** `retitle`, like a rebind, updates the window's metadata;
  the copy of the title inside the scene's own window record keeps the title
  the window was created with. Nothing reads that copy.

## Verification boundary

`tests/lifecycle_flow.rs` drives all of the above through the exported C ABI
and the JSON decoder, on an output whose bounds do not start at the global
origin and whose usable area is not the whole output, with synthetic
identities. Its expected positions are derived by hand from upstream's rules.

```sh
cargo test -p driftwm-desktop --test lifecycle_flow
```

Two of its scenarios cross into the neighbouring contracts: a held
`cycle-windows` followed by a close, for the one focus history, and
`state_event` across a window that appears, is renamed, becomes a stand-in and
is dismissed, for the [event stream](IPC.md#event-stream).

That establishes the controller contract and nothing more. It is no evidence
that the shell discovers a window, that a capture stream starts or stops, that
an identity is validated, that a close button is pressed, that an application
is launched, or that anything is drawn. Every effect in those scenarios is a
request nobody performs, and every "window" is a JSON object. Expiry is driven
there by `tick_navigation` timestamps the test picks, not by a clock. The
interplay with a live native resize transaction is covered only by
the existing guard: `window_closed` is refused while one is live on that window,
as `remove_source` is.

## The app's shell

[native/desktop/README.md](../../native/desktop/README.md#managed-windows) is
the user's account of it. In this contract's terms the shell
(`native/desktop/window-manager.m` and `main.m`):

- decides which native windows are windows at all. Upstream manages
  toplevels and their dialogs (`new_toplevel`) and never a popup, a tooltip or
  a helper surface, which Wayland tells apart by role; the Mac window list has
  no role, and a normal-layer window of a regular application may be a
  browser's status bubble. A candidate (normal layer, a regular application's,
  on screen, at least 40x40, still for one poll) is offered only when it is a
  real window: with Accessibility access, when its application reports it
  with the subrole `AXStandardWindow`, `AXDialog` or `AXSystemDialog`,
  whatever its size or title; one the application reports with another
  subrole is left alone. One its application does not list among its windows
  gets one more look (counted by itself: a window the shareable windows missed
  first still gets it) and is then judged as if Accessibility could not say,
  because an application lists only the windows of the active Space and a
  real window refused cannot be reached at all, while a helper adopted by
  mistake can be dismissed. Where Accessibility cannot say (no access, an
  application that does not answer in time, a window that gives no subrole or
  is not listed) the rule is the size floor it was, less the untitled window
  smaller than 200x150. A window of 200x150 or more that a subrole leaves out
  is named on stderr. The test is made once per appearance and only before
  adoption: a window already on the canvas is never asked again, so one that
  later stops being a standard window stays for the session, and a window
  that failed it is asked again when it next comes on screen. A window left
  out is not named in `present` either, so a slot an earlier run saved for it
  is dropped by the pass like any slot nothing matched. The chooser
  (`--manual`, or Choose windows) lists as it did and adds any of them by
  hand;
- sends the new-window `attach`, with `output` and `pointer`, for every
  candidate window it discovers that passes that test; `adoption_complete` after the first read of
  each window manager, so once at launch and once whenever the canvas is
  reopened after Return to desktop, with `present` built from the titled
  candidate windows of that read that exist but were not offered;
  `window_closed`, with `output`, when a managed window's number has left the
  window list or its process is gone; `retitle` when the title changes; and
  `remove_source` with `keep_placeholder`, as before, when a capture stream
  fails while the window is still there, and for every source on Return to
  desktop and quit;
- ticks the navigation clock on every poll (80 ms), except between Return to
  desktop and the canvas reopening: a relaunch that was pending when the canvas
  closed lapses at the first tick after it reopens if that long has passed.
  IPC is refused in that interval, so none is asked for with a clock that
  stands still;
- in a run without a window manager (`--manual`, or no Screen Recording
  access) sends `window_closed` instead of `remove_source` for a closed source
  that `snapshot.lifecycle.marks` names: a window that `close-window` or
  `suspend-window` asked to close leaves what the mark says. Every other lost
  source of such a run keeps its placeholder;
- follows `navigation` and `dirty` from those replies and hands their `effect`,
  the `focus_native_window` request of a new-window `attach` or a
  `window_closed` reply, to the navigation coordinator like the request of any
  other reply: performed on the native window and answered `focus_result`
  where native focus is allowed, answered `focus_logical` at once where it is
  not (no Accessibility access, or `--no-native-focus`). A reply without one
  withdraws only work in flight for a request the controller has dropped. No
  other effect comes with those replies;
- performs `close_window` and `launch` only from an `action` or `ipc` reply:
  `close_window` only for a source it bound itself whose identity and generation
  the controller still reports, pressing that window's close button through
  Accessibility after a fresh identity check; `launch` through `NSWorkspace` by
  bundle identifier. A press that was skipped (no Accessibility access, a
  binding that changed) leaves the mark to lapse by itself. A bundle identifier
  with no installed application is reported in the status line and on stderr
  after the IPC reply has already answered `Ok`, and the relaunch stays pending
  until it lapses; upstream answers `<name> is no longer installed` and records
  nothing;
- sends no new-window `attach` and no `adoption_complete` without Screen
  Recording access or with `--manual`: `settled` stays false for the whole run,
  no slot is dropped and `session.restore_windows` is never read.

### Live runs, 2026-10-09

The built app (`scripts/build-app.sh`, ad-hoc signed, macOS 27.2, Apple Silicon)
was launched four times on a private scene, config and socket and driven
through `Infinify msg`, each launch for a few seconds. The launches had no
Screen Recording and no Accessibility grant, so the last point above applied to
all of them: nothing here is evidence of discovery, adoption, placement,
capture, a close button press or an application launch, and no
`adoption_complete` was ever sent. Nothing from them is saved as evidence. The
scene was seeded through the controller with three windows attached at explicit
world rectangles and saved: "Notes", "Browser" and "Terminal", all with the
bundle identifier `org.example.seed`, which no application has. Loaded, they are
three waiting slots; none is a stand-in.

- `--windowed 1100x700`, empty config: the app owned one on-screen window of
  1100x700 at layer 0, stderr carried `Windows are not managed: Infinify has no
  Screen Recording access. …`, and `state` listed the three windows, all
  `suspended`, on one output `windowed` of 1100x636. Three seconds later
  `state` was the same: without a discovery pass nothing is dropped.
- In that launch: `focus --id 1` then `action close-window`: window 1 gone.
  `close --id 2`: gone. `suspend --id 3`: `window is already suspended`;
  `suspend --id 99`: `no window with id 99`; `relaunch --id 99`:
  `no suspended window matching selector`; each with exit status 1.
- `relaunch --id 3`: `ok`, and `Relaunch failed: no application with bundle
  identifier "org.example.seed" is installed` on stderr. Asked again about a
  second later: `ok` and no second line on stderr, the no-op for a relaunch
  that is pending. The app kept answering `state`. The thirty seconds were not
  waited out, so the lapse itself was not seen in the app.
- After SIGTERM the scene file held window 3 alone, no `standins` key, and no
  pid, window number, process birth, identity or generation.
- `--windowed 1100x700` on the reseeded scene with `[session] restore_windows =
  true`: the not-managed line again, three windows in `state` at once and three
  seconds later, and three in the file it saved at exit.
- `--manual` twice on that saved file with the same config: `state` listed the
  three windows and no output, stderr stayed empty, and the file still held the
  three after exit. In the second of them the app owned one on-screen window of
  720x502 at layer 4, the chooser, read from the system window list 1.5 s after
  the socket answered; in the first that list was read at once and was still
  empty.
- Every launch exited 0 on SIGTERM with its socket file removed.

`restore_windows` made no observable difference, as the contract says it cannot
without `adoption_complete`. Who follows a close, the held slots, a
refused config file, expiry on the clock and the pass of a reopened canvas are
not observable through `msg` in such a run; they rest on `lifecycle_flow`
alone.

Six earlier launches the same day, on the build before the review fixes (the
close tiers read no history of logical focus, no expiry, no `present`, one
`adoption_complete` per process), covered the same ground with one seeded stand-in: there `focus` on an
out-of-view stand-in flew the camera to it, `action suspend-window` on a
focused stand-in dismissed it, a saved stand-in was listed under `standins` and
read back at the next launch, and a repeated `relaunch` printed the failure
line each time, which this build no longer does.

One more launch the same day ran the build that holds this contract together
with [window navigation](NAVIGATION.md#window-navigation-actions), the
[event stream](IPC.md#event-stream) and autostart, again without Screen
Recording access and on three seeded waiting slots: dismissal by
`close-window`, the `Suspend` and `Relaunch` replies above and the pending
relaunch's no-op were the same, and a subscriber was sent the state without the
dismissed window. No window had a bound source, so no focus request and no
focus history entry was produced there. The
[shell notes](../../native/desktop/README.md#what-was-run-for-managed-windows)
list what was read.
