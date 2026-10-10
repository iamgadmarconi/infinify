# Actions, bookmarks and IPC, ABI 1

Three additive ABI 1 commands make the controller scriptable in DriftWM's own
words: `action` runs one upstream action string, `ipc` answers one upstream IPC
request, and `state_event` produces the lines of upstream's
[event stream](#event-stream). The exported `driftwm_desktop_msg` is the
matching `msg` client. All four are adapted from malbiruk/driftwm at
`352333a8fa1b22171492d4b71a54102045c9a19d` (`src/config/{types,parse}.rs`,
`src/input/actions.rs`, `src/ipc/{protocol,mod,client}.rs`). Existing commands,
their shapes, `ABI_VERSION` and `SAVE_VERSION` are unchanged.

The controller owns no socket. The shell reads one JSON line from a client,
passes it as `request`, performs what the reply asks of it, and writes `reply`
back as one line. No command here performs a native operation.

## `action`

```json
{"op":"action","output":1,"action":"go-to-bookmark 1"}
{"op":"action","output":1,"action":"cycle-windows forward","pointer":{"x":812.0,"y":440.5},"held":true}
```

`output` is the active output's logical id, or `null`. Two optional inputs say
what only the shell knows at the moment the action fires:

- `pointer` is the pointer's global screen point, in the coordinates `hit`
  takes. `focus-center` acts on the window under it; no other action reads it.
  Absent or `null` means unknown. A point outside the ±1e12 range is a
  controller error, `invalid pointer`.
- `held` is a real boolean, default `false`: true when a real modifier is
  physically down as the action fires, which upstream reads from the keyboard.
  Only `cycle-windows` reads it: a held step leaves the cycle open until
  [`end_focus_cycle`](FOCUS.md); a step that is not held is committed as a
  release would commit it. `0` and `1` are refused.

The reply is `{"navigation":<flight or null>,"effects":[…],"dirty":<bool>}`:

- `navigation` is the armed flight
  `{output,generation,target_camera,target_zoom,animating}` exactly as the
  [view actions](NAVIGATION.md#view-actions) return it, or `null` when nothing
  flies. Schedule frames while it is an object.
- `effects` are requests to the shell: `{"op":"quit"}`,
  `{"op":"exec","command":…,"env":{…}}`, `{"op":"reload_config"}`,
  `{"op":"warp_pointer","screen":{x,y},"output":…}`,
  `{"op":"switch_layout","target":…,"index":…}`, from the
  [window lifecycle](LIFECYCLE.md#actions-and-ipc)
  `{"op":"close_window","window":…,"identity":…,"generation":…}` and
  `{"op":"launch","bundle_id":…,"window":…}`, and, from the four window
  navigation actions and from a dismissal that moves the focus, at most one
  `{"op":"focus_native_window",effect_id,window,identity,generation}`. The
  controller performs none of them. The last is the [focus effect](FOCUS.md)
  `focus` and `navigate_window` return under `effect`: perform it and
  acknowledge it with `focus_result`, or answer it `focus_logical` when no
  native focus is performed in this run, and never read it as evidence that
  native focus changed. Focusing a detached placeholder adds no effect.
- `dirty` is true when saved state changed and the shell should save. Focus and
  stacking are saved, so a window navigation that focuses a window is dirty,
  and so is one that clears a focus.

The string is parsed by upstream's own `parse_action`, from `driftwm-core`; the
same grammar reads the [config file](CONFIG.md)'s bindings. The first
whitespace-delimited word is the name and the trimmed remainder its argument.
Names are case-sensitive kebab-case; directions (`up`, `down`, `left`, `right`,
`up-left`, `up-right`, `down-left`, `down-right`) are case-insensitive.

| Action | Runs here | Effect |
| --- | --- | --- |
| `pan-viewport <dir>` | yes | the `pan_viewport` command |
| `center-window` | yes | focuses and flies to the focused window, else the window nearest the viewport center, at zoom 1 |
| `center-nearest <dir>` | yes | focuses and flies to the nearest window in that direction at the current zoom, or flies to a `navigation.anchors` point and clears focus |
| `cycle-windows forward`, `cycle-windows backward` | yes | one step through the focus history, flown to at the current zoom; reads `held` |
| `focus-center` | yes | focuses and flies to the window under `pointer`, at zoom 1 |
| `home-toggle` | yes | the `home_toggle` command |
| `zoom-in`, `zoom-out`, `zoom-reset`, `zoom-to-fit` | yes | the command of the same name |
| `go-to-bookmark <name>` | yes | flies to the bookmark; `navigation` is `null` when there is none |
| `set-bookmark <name>` | yes | stores the bookmark; `dirty` is true, `navigation` is `null` |
| `quit` | yes | `effects` is `[{"op":"quit"}]`; needs no output |
| `nudge-window <dir>` | yes | moves the focused window by `navigation.nudge_step`; `dirty` is true; needs no output |
| `exec <cmd>`, `spawn <cmd>`, `exec-terminal`, `exec-launcher` | yes | `effects` is one `exec` for the shell to run; needs no output |
| `reload-config` | yes | `effects` is `[{"op":"reload_config"}]`; needs no output |
| `send-to-output <dir>` | yes | moves the focused window to the adjacent output; `dirty` is true when it moved; needs an output only when no output shows the window |
| `send-cursor-to-output <dir>` | yes | `effects` is one `warp_pointer`, or empty with no adjacent output |
| `switch-layout next`, `prev`, `<index>` | yes | `effects` is one `switch_layout`; needs no output |
| `close-window` | yes | a focused live window: `effects` is one `close_window`, marked a real close for the next ten seconds; a focused placeholder is dismissed and `dirty` is true; needs no output |
| `suspend-window` | yes | a focused live window: `effects` is one `close_window`, and a stand-in takes its place if it closes within ten seconds; a focused placeholder is dismissed; needs no output |
| `toggle-cursor-pan` | yes | flips [cursor edge pan](MOTION.md#cursor-edge-pan); `navigation` is `null`; needs no output |
| `set-trackpad on\|off\|toggle` | yes | turns [gesture](GESTURES.md#set-trackpad) dispatch on or off; needs no output |
| `grow-window`, `shrink-window`, `move-to-bookmark`, `zoom-to-fit-snapped`, `toggle-fullscreen`, `fit-window`, `fit-window-snapped`, `fill-window`, `toggle-pin-to-screen` | no | parsed with upstream's argument rules, then refused |

[NAVIGATION.md](NAVIGATION.md#window-navigation-actions) describes the four
window navigation actions, [CONFIG.md](CONFIG.md#actions-that-run-now) the
nudge, exec and reload actions, [Outputs](CONFIG.md#outputs) the two output
actions, [Keyboard layouts](CONFIG.md#keyboard-layouts) `switch-layout`,
[LIFECYCLE.md](LIFECYCLE.md#actions-and-ipc) the close and suspend actions,
[MOTION.md](MOTION.md#cursor-edge-pan) `toggle-cursor-pan` and
[GESTURES.md](GESTURES.md#set-trackpad) `set-trackpad`.
An `exec` effect is not run by the controller. Because `ipc`
accepts `{"Action":…}`, whoever can write to the shell's socket can have the
shell run a command, as with upstream's `driftwm msg action exec`.

A refused action is a controller error and changes nothing. Three refusals are
kept apart and checked in this order:

1. The string does not parse: upstream's own message, such as
   `unknown action: frobnicate`, `pan-viewport requires a direction`,
   `unknown direction: north`, or `set-trackpad: expected on, off, or toggle, got 'maybe'`.
2. It parses but does not run here: `action not implemented on macOS yet: <name>`,
   with or without an output.
3. It needs an output and `output` is `null`: `no active output`.

`go-to X Y` is not a canvas-point jump. Upstream removed it before the pinned
commit and its parser answers
`go-to was removed — save the point as a bookmark and use go-to-bookmark <name>`,
which is what this one answers too. `resize-window` and `resize-window-snapped`
keep upstream's "drag action" message. An unknown output rejects, and every
action that arms a flight rejects during an active drag or resize gesture,
exactly as the direct commands do.

`go-to-bookmark` with a name that is not set is not an error upstream, and is
not one here: the reply is `{"navigation":null,"effects":[],"dirty":false}`. For
this action `navigation` is `null` only in that case.

Upstream's `execute_action` first ends an Alt-Tab cycle in progress, committing
its selection, unless the action is itself `cycle-windows`, and stops the active
output's scroll momentum. So does `action`, for every action that parses, `quit`
and `exec` included, and so do [`hot_corner`](CONFIG.md#hot-corners), which runs
its corner's action through the same handler with the same `pointer` and `held`,
and a [gesture](GESTURES.md) whose threshold or hold fires one. A selection
whose request was answered (confirmed, or `focus_logical`) moves to the head of
the focus history, and one still waiting for its answer is promoted by that
answer instead (see [FOCUS.md](FOCUS.md#upstream-entry-points)). The momentum
that stops is that of the output the action runs on, so an action sent with no
output stops none: see [camera motion](MOTION.md#what-stops-momentum). A refused
action rolls the cycle and the momentum back with everything else. The direct
commands (`pan_viewport`, `zoom_in`, …) are not actions and leave a cycle alone;
they stop their own output's momentum.

## Bookmarks

A bookmark is a name and a canvas point `[x, y]`: upstream's user-facing
convention, a **center** point with **Y up**. It never stores zoom. The map is
separate from `driftwm_canvas::Scene`'s own camera-and-zoom bookmarks, which
nothing here reads or writes. Names are unrestricted strings, as upstream's are.
Neither their length nor their number is bounded, so enough of them push the
save past its 32 MiB limit, and every save then fails until some are deleted.

- `set-bookmark` stores the canvas point under the output's **usable center**
  (the navigation context's `usable_rect_local` center): with camera `c` and
  zoom `z`, `[c.x + center.x / z, -(c.y + center.y / z)]`. A pending camera
  target is used instead of the current camera, so a bookmark set during a
  camera-only flight (`pan-viewport`, `go-to-bookmark`, a `Camera` write) is
  where the flight was heading. An anchored
  zoom flight (home toggle, a zoom step, fit, their returns, a `Zoom` write,
  window navigation) drops its camera target on its first tick, as upstream's
  does, so a bookmark set during one is the point under the usable center at
  that moment; set before the first tick, it pairs the flight's camera target
  with the zoom still in effect, which is the destination only when the flight
  keeps the zoom.
- `go-to-bookmark` is the exact inverse: it flies the camera to
  `(x - center.x / z, -y - center.y / z)` at the current zoom and disarms a
  zoom-to-fit return. Only the camera target is written, as upstream's
  `set_camera_target` does. A pending anchored zoom flight (a window navigation,
  home toggle, zoom step or fit still in the air) therefore keeps flying and its
  next tick drops the bookmark target: upstream behaves the same, and the reply's
  `target_camera` is then not where the camera comes to rest.
- Under a loaded [config](CONFIG.md#session) the map is a registry seeded from
  `[navigation.bookmarks]`, and `session.restore_bookmarks` decides whether a
  saved map comes back and whether runtime edits are written. What follows
  describes a controller no config was loaded into.
- The map is saved under the top-level `bookmarks` key of the save file. The key
  is additive under save schema 1: a file without it loads with no bookmarks,
  and it is omitted while the map is empty. A build from before bookmarks
  rejects a file that has the key, so only a save with no bookmarks stays
  readable by it.
- Numbers are parsed exactly (`serde_json`'s `float_roundtrip` feature, enabled
  in this crate's manifest): the coordinate a request sets is the one stored,
  saved and read back after a reload. Without it a fractional coordinate could
  land one unit in the last place away, which the first live run showed.
- Each output has an **active bookmark**: the visible bookmark nearest its
  usable center, from `driftwm_canvas::policy::active_bookmark` with upstream's
  hysteresis for the incumbent. Upstream re-evaluates it once per rendered
  frame; here it is re-evaluated after every accepted command, `tick_navigation`
  included, so the incumbent follows the poses the camera actually passed
  through. Incumbents are ephemeral: never saved, empty after load.

`snapshot` gains two keys: top-level `bookmarks`, and
`navigation.active_bookmarks` keyed by output id.

## `ipc`

```json
{"op":"ipc","output":1,"request":{"Camera":[500,300]}}
```

`request` is one upstream `Request` in its wire form; `output` is the active
output (upstream: the one under the pointer), or `null`. An optional `pointer`
is the pointer's global screen point, as for `action`: `{"Action":"focus-center"}`
reads it. A request is never `held`: an IPC `cycle-windows` is a single
committed step, as upstream's modifier-less fire is. The reply is

```json
{"reply":{"Ok":{"Camera":{"x":500.0,"y":300.0}}},"effects":[],"dirty":false,"navigation":{…}}
```

`reply` is upstream's `Reply`: `{"Ok":<Response>}` or `{"Err":"message"}`.
`effects`, `dirty` and `navigation` mean what they mean for `action`. A request
that does not decode (`invalid request: …`) or is refused becomes an `Err` reply
with empty `effects`, `dirty` false and `navigation` null. It is never a
controller error, and it leaves every bit of controller state as it was. Only a
malformed command is a controller error: no `request`, a non-integer `output`,
an unknown field, or a number literal anywhere in it that no `f64` holds
(`1e999` inside `request` included, since the command is parsed as a whole
before the request is decoded).

`effects` may hold the existing focus effect
`{"op":"focus_native_window",effect_id,window,identity,generation}`. It is the
same obligation `focus` and `navigate_window` return under `effect`: perform it
and acknowledge it with `focus_result`, or answer it `focus_logical`, or it
stays pending until superseded. It is never evidence that native focus
changed. The same obligation comes back under `effect` from a new-window
`attach` and from `window_closed`. `ipc` can also return the other effects
`action` does, and `{"op":"subscribe","line":…}` for a `Subscribe` request.
Which effects the app's shell performs is the
[shell's](../../native/desktop/README.md) to say.

### Coordinates

Upstream speaks center points with Y up; the controller's world is top-left
with Y down. Two centers are in play and they are not interchangeable:

- `Camera`, `StateInfo.camera` and `OutputInfo.camera` are the center of the
  **whole output** (`policy::viewport_center` / `camera_for_center` over the
  `screen_bounds` size), as upstream's `camera_center` is.
- Bookmarks, zoom anchoring and the focus visibility test use the **usable
  rectangle**, as upstream's `usable_center_screen` and usable area are.

Only `screen_bounds`, the navigation context and world rectangles are read, and
of `screen_bounds` only the size enters any camera or window position. Its
origin is read in two places: the adjacency of outputs, and the screen point of
a `warp_pointer` effect. Observed and original native rectangles never enter
the math.

Window positions and sizes cross upstream's integer boundary: a world
rectangle's top-left and size are each rounded to the nearest whole point, and
`internal_to_rule` / `rule_to_internal` then apply with upstream's truncating
halving: position `(x + w / 2, -(y + h / 2))`. A native frame already includes
its title bar and there is no compositor border, so chrome is zero. Geometry
outside the `i32` range is refused rather than saturated, on a read and on a
`Move` write alike: a destination is refused when its top-left would not round
into `i32` or its far edge would pass `i32::MAX`.

### Requests

| Request | Needs `output` | Behavior |
| --- | --- | --- |
| `"State"` | no | The snapshot below. |
| `{"Camera":null}` | yes | `Camera{x,y}`: the output's viewport center. |
| `{"Camera":[x,y]}` | yes | Flies the viewport center to the point at the current zoom and echoes the request. Refuses non-finite numbers. Like `go-to-bookmark` it writes only the camera target; unlike it, a zoom-to-fit return stays armed, as upstream leaves it. |
| `{"Zoom":null}` | yes | `Zoom(z)`: the current zoom. |
| `{"Zoom":z}` | yes | Clamps to `[dynamic minimum, 1]` (the minimum `zoom_out` uses), flies there anchored on the usable center and replies with the clamped value. Refuses non-positive numbers. No snap to 1 and no "never zoom in" rule: the value is explicit. |
| `{"Focus":null}` | no | `Focused({id,app_id})` for the logical focus, or `Focused(null)`. |
| `{"Focus":<selector>}` | yes | Logical focus and raise, plus upstream's camera rule: a frame already wholly inside the usable area is only focused; a window with a bound source is navigated to at zoom 1, or at the current zoom when `zoom.reset_on_activation` is off, exactly as `navigate_window` does; a detached placeholder is panned to at the current zoom, as upstream's `reveal_suspended` does for a stand-in. `effects` holds the focus effect when the window has a bound source; `dirty` is true because focus and stacking are saved. |
| `{"Move":{window?,to?}}` | no | Without `to`: `Position{x,y}`, the frame's center. With `to`: a logical world move that puts the frame's top-left on whole points and keeps its size; `dirty` is true. Refused while a drag or resize gesture is installed, while a native resize transaction on that window is live, and when the destination frame would leave the `i32` range (`window geometry exceeds integer range`). |
| `{"Resize":{window?,to?}}` | no | Without `to`: `Size{width,height}`. With `to`: `Err`, `resize is not implemented on macOS yet: native layout resize is not available` (a non-positive size gets upstream's `size must be positive`). |
| `{"Action":"…"}` | per action | Runs the `action` command's handler. `Ok` whenever it runs, even with no effect; every refusal above is an `Err` reply. |
| `{"Bookmark":{name?,to?,delete?}}` | no | Upstream's four forms: list (`Bookmarks{…}`, sorted by name), get and set (`Bookmark{x,y}`), delete (`Ok`). Set and delete report `dirty`. Errors are upstream's: `no bookmark named '…'`, `bookmark delete requires a name`, `bookmark delete does not take coordinates`, `bookmark coordinates require a name`, `bookmark coordinates must be finite`. |
| `"DebugCounters"` | no | Sizes of the controller's own collections, keyed by field name. Unstable. |
| `{"Close":<selector or null>}` | no | Upstream's `cmd_close`. A live window: `Ok`, `effects` is one `close_window`, and the close is marked real so `session.suspend_on_close` leaves no stand-in. Else a detached placeholder: dismissed, `Ok`, `dirty`. Else the selector's `Err`. |
| `{"Suspend":<selector or null>}` | no | Upstream's `cmd_suspend`. A live window is focused first if it is not (a focus effect, `dirty`, no camera move), then the `suspend-window` action runs: `Ok`, `effects` ends with one `close_window`. A detached placeholder: `Err("window is already suspended")`. |
| `{"Relaunch":<selector or null>}` | no | Upstream's `cmd_relaunch`. A detached placeholder: `Ok`, `effects` is one `launch`, and the next window of that app to appear within thirty seconds takes the placeholder's slot; while that relaunch is pending the request is `Ok` with no effect, upstream's no-op. Anything else: `Err("no suspended window matching selector")`. A placeholder without a bundle identifier: `Err("the app has no bundle identifier to relaunch")`. |
| `{"Layout":{"short":false}}` | no | `Layout(name)`: the display name of the keyboard layout the shell last reported with [`layout_changed`](CONFIG.md#keyboard-layouts), or `""` before any report. |
| `{"Layout":{"short":true}}` | no | `Layout(short)`: its short code, or the display name when the code is empty, as upstream falls back. |
| `"Subscribe"` | no | `Ok`, and the effect `{"op":"subscribe","line":…}` carrying the current snapshot. See [Event stream](#event-stream). With an `output` that is not registered: `Err("unknown output")`, as `State`. |
| `{"Opacity":…}`, `{"Pin":…}`, `{"Screenshot":…}` | no | Decoded, then `Err`: `<name> is not implemented on macOS yet`, with the `msg` command's name. |

A missing output where one is needed is `Err("no active output")`; an id that is
not registered is `Err("unknown output")`. Camera and zoom writes reject with
`navigation during active gesture` while a gesture is installed.

A selector is upstream's: a JSON number is an Infinify logical window id, exact;
a JSON string is a case-insensitive substring of the bundle id. Among several
matches a window with a bound source wins over a detached placeholder
(upstream's live client over stand-in); within each group stage order decides.
No selector means the focused window, or `no focused window`. `Close`,
`Suspend` and `Relaunch` keep upstream's two tiers apart: `Close` and `Suspend`
look among windows with a bound source first and then among detached
placeholders, `Relaunch` among detached placeholders only, by id, by app id and
by focus alike. [LIFECYCLE.md](LIFECYCLE.md) has what each then does.

### State

`StateInfo` has upstream's fields in upstream's order. `camera` and `zoom` are
the active output's; with no active output they read `[0.0, 0.0]` and `1.0` and
no output is marked active. `layout` and `layout_short` are what the `Layout`
request answers, long and short.
`fullscreen`, `pinned`, `layers` and `canvas_layers` are always empty: none of
those exist here.

- `windows`: every Scene window, the focused one first and the rest in stage
  order (bottom to top). `id` is the logical window id, `app_id` the bundle id,
  `title` the last attached title, `position` and `size` the frame as above.
  `suspended` is true for a window with no bound source: a detached placeholder
  is Infinify's stand-in. `is_widget` is false and `mode` is `"Normal"`.
- `outputs`: connected outputs in registration order. `name` is the output's
  stable id, `camera` its viewport center, `size` its logical size, `active`
  whether it is the request's output, `active_bookmark` its incumbent.
- `active_bookmark`: the active output's.

JSON object members arrive in alphabetical order, not upstream's declaration
order, because replies travel through the ABI's `serde_json::Value`. Member
order carries no meaning in JSON; the `msg` client re-serializes the typed reply
and so prints `--json` in upstream's order.

## Event stream

Upstream's `Subscribe` turns a connection into a feed: an `{"Ok":"Ok"}` ack, the
current state as one `{"State":{…}}` line, then one such line whenever the state
changes. The controller produces every line; the socket is the shell's.

`{"op":"ipc","output":…,"request":"Subscribe"}` answers `reply: {"Ok":"Ok"}`
and one effect:

```json
{"op":"subscribe","line":"{\"State\":{\"camera\":[500.0,-400.0],\"zoom\":1.0,…}}"}
```

`line` is the whole event line without its newline: upstream's
`Event::State(StateInfo)` serialized from the typed value, so its members are in
upstream's order and its floats keep their `.0`. The shell writes the ack, then
`line` byte for byte, and keeps the connection as a subscriber. A second
`Subscribe` on one connection gets the ack and the snapshot again, as upstream.

```json
{"op":"state_event","output":1}
```

is upstream's `broadcast_state_event`. `output` is the active output or `null`.
The reply is `{"line":"…"}` when the event differs from the last one this
command returned, and `{"line":null}` when it is the same: the comparison is a
hash of the serialized bytes, as upstream's. A non-null `line` goes to every
subscriber. A `Subscribe` snapshot does not move that baseline, so the first
`state_event` of a run always returns a line. An `output` that is not
registered is a controller error, `unknown output`, and moves nothing.

The shell calls `state_event` while it has subscribers, after every redraw and
every `layout_changed` (so after any request, gesture or tick that may have
changed what `State` reports), and at most once per frame while a flight
animates, a camera [coasts](MOTION.md) or an edge pan runs. It also calls it
once while answering a `Subscribe`, before the new
connection joins: earlier subscribers then get a change not yet sent to them,
and the newcomer, whose snapshot is that same state, is not sent it twice. The
active output is part of the state: it decides the top-level `camera`, `zoom`,
`active_bookmark` and each output's `active`. The shell also redraws at every
idle poll, 80 ms apart, so a change of active output alone (the pointer moving
to another display) is reported by itself within one poll. Upstream buffers
at most the event in flight and the newest queued one for a subscriber that
reads slowly, and never drops a connection for it; how the shell bounds and
drops subscribers is in the
[shell notes](../../native/desktop/README.md#event-stream).

## `msg` client

```c
int32_t driftwm_desktop_msg(int32_t argc, const char *const *argv);
```

`argv` holds the arguments after `msg`. The function parses them, connects,
writes one request line, reads one reply line, prints it and returns the exit
status. It needs no controller; the shell calls it before any AppKit
initialisation.

```
infinify msg [--json] [--socket PATH] <command> [arguments]
```

Commands and arguments are upstream's (`docs/cli.md`): `state`, `subscribe`,
`focus [APP_ID] [--id ID]`, `move [X] [Y] [--id ID]`,
`resize [WIDTH] [HEIGHT] [--id ID]`, `close`, `suspend` and `relaunch`
`[APP_ID] [--id ID]`, `opacity [VALUE] [--id ID]`, `pin [on|off] [--id ID]`,
`camera [X] [Y]`, `zoom [LEVEL]`, `bookmark [NAME] [X] [Y] [--delete]`,
`layout [--short]`, `action <SPEC>...`,
`screenshot [--scale S] [-o PATH] [window [APP_ID] [--id ID] | all | region X Y W H [--from-screen]]`
and `debug-counters`. Negative numbers are values where upstream allows them
(`move`, `camera`, `bookmark`, `screenshot region`). Everything after `action`
is its spec, joined by single spaces. Parsing is by hand; there is no clap.

- Socket: `--socket PATH`, else `$INFINIFY_SOCKET`, else
  `~/Library/Application Support/Infinify/infinify.sock`. The app sets
  `INFINIFY_SOCKET` to the socket it serves in the environment of every command
  it starts (`exec`, `spawn`, `autostart`), so a `msg` run from one of them
  reaches that instance without `--socket`: the stand-in for upstream's
  `WAYLAND_DISPLAY` in `child_env`.
- `--json` prints the reply as pretty JSON; otherwise the rendering is
  upstream's `print_response` / `print_state`, which is not a stable format.
- Exit status 0 on an `Ok` reply. Exit status 1 with `error: …` on stderr for an
  `Err` reply, a connection failure (`cannot connect to <path>: …`), an
  unreadable reply, or a request the client refuses to send (a lone coordinate,
  a non-positive size, a non-finite number). With `--json` an `Err` reply is
  printed to stdout as JSON and the status is 1 with nothing on stderr, as
  upstream does. Exit status 2 with `error: …` on stderr for a usage error.
  `-h` / `--help` prints the command list and exits 0.
- Beyond upstream, `--json` and `--socket` are also accepted after the command
  (except inside an `action` spec), and `--socket` and `$INFINIFY_SOCKET`
  replace `DRIFTWM_SOCKET` / `WAYLAND_DISPLAY`. A non-finite `zoom` or `camera` argument (`nan`, `inf`) is
  refused by the client as `opacity` and `bookmark` ones are; upstream's client
  sends those two as `null`, which reads the zoom back with status 0 and fails
  to decode as a camera write.
- `subscribe` reads the ack and then, as upstream's `stream_events` does,
  prints every pushed line until the server hangs up, flushing after each:
  the line itself with `--json`, else upstream's `print_state` block and a
  blank line. Without `--json` a line that is not an event ends the client with
  status 1. An `Err` ack is reported like any other `Err` reply.
- `screenshot` builds upstream's request (an absolute path, a temporary file
  for `-o -`) and prints the server's refusal.

## Differences from upstream

- `Move` does not raise the window: Scene has no raise without focus. Upstream
  raises a live client and activates it only when it was already focused.
- Camera and zoom writes, and `go-to-bookmark`, reject during a drag or resize
  gesture, as every navigation command here does. Upstream has no such gate.
- Fullscreen does not exist here, so nothing exits it.
- `Focus` with no active output is refused instead of focusing without a camera.
- `{"Action":"cycle-windows …"}` is always a single committed step. Upstream
  keeps the session open when a real modifier happens to be down as the request
  arrives.
- `{"Action":"focus-center"}` uses the `pointer` the shell passes with the
  command; with none it does nothing. Upstream reads its own seat.
- `StateInfo` without an active output reports the origin at zoom 1.
- The active bookmark is re-evaluated per accepted command, not per frame.
- Reply member order (above). An event line is not a reply: it is a string the
  controller serialized itself, in upstream's order.
- Upstream detects a state change from its own dirty flags once per rendered
  frame and then compares the event's hash. Here nothing is rendered by the
  controller: the shell asks with `state_event` and only the hash comparison
  remains, so an event goes out exactly when the serialized state differs.
- Upstream's `Subscribe` can fail with `cannot subscribe: <io error>` when the
  connection cannot be cloned. The controller owns no connection and always
  acks; a refusal for want of room is the shell's to send.
- The app's shell parses each client line with `NSJSONSerialization` and
  re-encodes it into the command, so the controller never sees the client's own
  bytes. A whole-valued float in an integer field
  (`{"Move":{"window":1,"to":[100.0,200.0]}}`) reaches it as an integer and is
  accepted, where upstream's decoder, and this controller given those bytes,
  refuse it. A line that round trip cannot carry, such as one holding `1e999`,
  answers `{"Err":"invalid request"}` without reaching the controller.

## Evidence and limits

`tests/ipc_flow.rs` drives the exported C ABI with upstream-shaped request JSON
and checks reply shapes and resulting controller state: the `State` shape,
camera and zoom round trips on outputs whose `screen_bounds` origin is not the
global origin and whose usable center differs from the output center, bookmark
set / go-to / list / delete and the save file with and without the `bookmarks`
key, `Move` with its range refusal, `Focus` of a bound window (zoom 1) and of a
placeholder (current zoom), every refused, unknown and unimplemented request
against an unchanged `snapshot`, and an accept / reject table for the action
grammar. The window navigation actions, `pointer`, `held` and the cycle prelude
are covered by `tests/navigation_actions_flow.rs`, described under
[Window navigation actions](NAVIGATION.md#window-navigation-actions). The client is driven through `driftwm_desktop_msg` against a throwaway
`UnixListener` in the temporary directory: the request line it sends, its exit
statuses, and one round trip in which the test stands in for the shell and
answers from a real controller's `ipc` command.

`tests/platform_actions_flow.rs` covers the `subscribe` effect and
`state_event`: the line against the `State` reply and upstream's member order,
the baseline across changing and unchanging requests, a change of active
output, and each frame of a flight. In `tests/ipc_flow.rs` the client's
`subscribe` runs against a throwaway listener that answers as the shell would,
from a real controller: the ack, the effect's line, every `state_event` line,
then a hang-up, in both output forms, and once with a line that is not an
event.

Not covered by tests: the client's printed output (only its exit status and
request line are asserted; for `subscribe` without `--json`, status 0 also says
every line decoded as upstream's typed event), the `$INFINIFY_SOCKET` and
default-path resolution, and the `screenshot -o -` relay, which needs a server
that answers `Ok`. The shell's side of the stream is not covered by these tests
at all: its socket writes, its subscriber limit, how it drops a peer that stops
reading, and when it calls `state_event`. Two launches of the built app on
2026-10-09, described in the
[shell notes](../../native/desktop/README.md#what-has-been-run), observed the
stream over the real socket (the ack and first line, one line per frame of a
flight and none while idle, no repeated line, the limit of eight, requests on a
subscribed connection, a clean end on exit); they left no saved evidence and
did not reach the stalled-subscriber drop. Upstream's own sources are not
executed: expected values are worked out from the adapted formulas, not from an
oracle build.

The tests are logical controller behavior only. Nothing in them opens a socket
in the app, registers a hot key, moves or focuses a native window, renders, or
captures.

### Live run, 2026-10-09

The built app (`scripts/build-app.sh`, ad-hoc signed, macOS 27.2, Apple Silicon)
was launched as `--windowed 1100x700` on a private scene file and socket, with a
seeded scene of three detached placeholders (frames 640x420 at (200, 150),
900x600 at (1500, -300) and 560x380 at (-900, 700), top-left and Y down), and
driven by a script through `Infinify msg` and a few raw socket lines, in several
runs; the last two, identical in every value read, were made after the review
fixes (focus zoom chosen by binding, the
`Move` range refusal, the client's non-finite refusal). Nothing from them is
saved as evidence. Observed, each read back through the socket:

- `state`: three windows at `[520, -360]`, `[1950, 0]` and `[-620, -890]`, all
  `suspended`, and one output `windowed` of 1100x636, camera `550 -318`, zoom 1.
- `camera 400 -250` and `zoom 0.5` landing on those values, and `camera 0 0`
  landing in the first full run and five of six short launches (see below);
  `zoom 0.01` answering and landing on 0.14242424242424243 and `zoom 5` on 1.
- `action zoom-in`, `zoom-out`, `zoom-reset`: 0.5 to 0.55, back to 0.5, to 1.
- `action zoom-to-fit`: camera `750 -390`, zoom 0.28484848484848485, which is
  the center of the seeded bounding box and (1100 - 160) / 3300; a second one
  returned to the pose left.
- `action home-toggle` from camera `400 -250` at zoom 0.5: to the origin at zoom
  1, and back on the second.
- `action pan-viewport right` at zoom 0.5: 200 canvas points; `up-left`: 200
  along the diagonal.
- `bookmark` set, get, list and delete; `action set-bookmark` storing the point
  `camera` reports (the app registers no usable area, so the two centers
  coincide there); `action go-to-bookmark` landing the camera on a bookmark with
  the zoom unchanged and `active_bookmark` naming it; an unset name answering Ok.
- `move --id 2 100 200`: read back as `100 200`, saved as top-left (-350, -500).
- `move --id 1` to `-2147483648 0`, `2147483647 0` and `0 2147483647`: each
  `window geometry exceeds integer range` with exit status 1. Afterwards
  `move --id 1` still read `520 -360`, `state` answered, and `action zoom-to-fit`
  framed the moved layout (camera `-30 -290`, zoom 0.3012658227848101, which is
  (636 - 160) / 1580) and returned.
- `focus --id 3` at zoom 0.5 with that window partly out of view: the reply
  names the window, the camera lands on its center `-620 -890` with the zoom
  still 0.5, and `focus` reads it back. `focus example.SEED` then lands on
  window 1's center `520 -360`, again at 0.5, and focusing window 1 once more,
  now wholly in view, moves nothing. The scene file records the focus. Every
  window was a placeholder, so no focus effect was produced and a bound
  window's zoom-1 navigation was not seen. In the runs before the fix a
  placeholder focused this way landed at zoom 1.
- `zoom nan`, `zoom inf` and `camera inf 0`: refused by the client with exit
  status 1 and the zoom unchanged.
- On the raw socket, `{"Move":{"window":1,"to":[520.0,-360.0]}}` answering
  `{"Ok":{"Position":{"x":520,"y":-360}}}` and `{"Camera":[1e999,0]}` answering
  `{"Err":"invalid request"}`: the shell's re-encoding described under
  [Differences from upstream](#differences-from-upstream).
- `unknown action: frobnicate`, `action not implemented on macOS yet:
  toggle-fullscreen`, `unknown direction: sideways`, the `go-to` removal
  message, the `resize` write refusal and the eight `<name> is not implemented
  on macOS yet` replies (three since: `layout` and `subscribe` are answered
  now, and `close`, `suspend` and `relaunch` since the
  [lifecycle](LIFECYCLE.md) work), each
  with exit status 1; `{"Err":"invalid request"}`
  for a line that is not JSON.
- The reply's alphabetical member order on the raw socket; the client's output
  in both forms; `$INFINIFY_SOCKET`.
- The scene file holding the bookmarks, the moved window, the focus and the
  camera, and a second launch reading them back.

Two flights in the runs before the fixes, both `camera 0 0` as the first write
after a launch (one full run and one short launch), stopped part-way along
their path, and one later flight ended 0.31 points off in x alone. A press or
scroll on a canvas stops or pans a flight by design and the machine was in use,
so pointer input reaching the panel is the likely cause; that was not
confirmed. Every other flight landed exactly, every one in the last two runs
included.

The last two runs did not repeat `zoom 0.01` and `zoom 5`, the `zoom-in`, `zoom-out`
and `zoom-reset` actions, `pan-viewport up-left`, `go-to-bookmark` with an unset
name, `unknown direction: sideways`, the `go-to` removal message, the eight
`<name> is not implemented on macOS yet` replies, the member order,
`$INFINIFY_SOCKET` and the second launch: those stand as observed on the build
before the fixes.

Not observed: bound sources (so no focus effect, no zoom-1 focus navigation and
no live-over-placeholder choice), more than one output, a request with no active output, a request
during a gesture, and anything drawn. This run is no evidence of usable
native-window compositing or of native focus delivery.
