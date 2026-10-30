# Actions, bookmarks and IPC, ABI 1

Four ABI 1 commands make the controller scriptable in DriftWM's own
words: `action` runs one upstream action string, `ipc` answers one upstream IPC
request, `state_event` produces the lines of upstream's
[event stream](#event-stream), and `screenshot_result` completes the one
request the controller cannot answer by itself
([RENDER.md](RENDER.md#screenshots)). The exported `driftwm_desktop_msg` is the
matching `msg` client. All five are adapted from <https://github.com/malbiruk/driftwm> at
`352333a8fa1b22171492d4b71a54102045c9a19d` (`src/config/{types,parse}.rs`,
`src/input/actions.rs`, `src/ipc/{protocol,mod,client}.rs`).

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
| `center-window` | yes | focuses and flies to the focused canvas window, else the canvas window nearest the viewport center, at zoom 1; a window still [filled](SIZES.md#fill-window) returns to the camera and zoom its fill ran in instead |
| `center-nearest <dir>` | yes | focuses and flies to the nearest canvas window in that direction at the current zoom, or flies to a `navigation.anchors` point and clears focus |
| `cycle-windows forward`, `cycle-windows backward` | yes | one step through the focus history, which holds canvas windows only, flown to at the current zoom; reads `held` |
| `focus-center` | yes | focuses and flies to the canvas window under `pointer`, at zoom 1, with `center-window`'s fill exception; a pinned window there is passed over and a widget is not taken |
| `home-toggle` | yes | the `home_toggle` command |
| `zoom-in`, `zoom-out`, `zoom-reset`, `zoom-to-fit` | yes | the command of the same name |
| `go-to-bookmark <name>` | yes | flies to the bookmark; `navigation` is `null` when there is none |
| `set-bookmark <name>` | yes | stores the bookmark; `dirty` is true, `navigation` is `null` |
| `quit` | yes | `effects` is `[{"op":"quit"}]`; needs no output, and the controller refuses it in no state. The shell performs it by ending cleanly, with exit status 0: the one end launchd does not restart ([CONFIG.md](CONFIG.md#started-at-login)). What the shell holds back before the controller is asked is the shell's: an unresolved native resize gates it ([SIZES.md](SIZES.md)), and its socket answers no request, this one included, while a saved scene could not be loaded |
| `nudge-window <dir>` | yes | moves the focused window by `navigation.nudge_step`; `dirty` is true; needs no output |
| `exec <cmd>`, `spawn <cmd>`, `exec-terminal`, `exec-launcher` | yes | `effects` is one `exec` for the shell to run; needs no output |
| `reload-config` | yes | `effects` is `[{"op":"reload_config"}]`; needs no output |
| `send-to-output <dir>` | yes | moves the focused window to the adjacent output, a pinned one by its pin; a widget stays; `dirty` is true when it moved; needs an output only when no output shows the window |
| `send-cursor-to-output <dir>` | yes | `effects` is one `warp_pointer`, or empty with no adjacent output |
| `switch-layout next`, `prev`, `<index>` | yes | `effects` is one `switch_layout`; needs no output |
| `close-window` | yes | a focused live window: `effects` is one `close_window`, marked a real close for the next ten seconds; a focused placeholder is dismissed and `dirty` is true; needs no output |
| `suspend-window` | yes | a focused live window: `effects` is one `close_window`, and a stand-in takes its place if it closes within ten seconds; a focused placeholder is dismissed; needs no output |
| `toggle-cursor-pan` | yes | flips [cursor edge pan](MOTION.md#cursor-edge-pan); `navigation` is `null`; needs no output |
| `set-trackpad on\|off\|toggle` | yes | turns [gesture](GESTURES.md#set-trackpad) dispatch on or off; needs no output |
| `move-to-bookmark <name>` | yes | centers the focused canvas window on the bookmark and raises it; `dirty` when it moved; a missing bookmark, a widget and a pinned window are passed over; needs no output |
| `toggle-pin-to-screen` | yes | pins the focused live window to the screen where it shows, or returns it to the canvas there; `dirty` when the pin changed; see [RULES.md](RULES.md#screen-pinned-windows) |
| `zoom-to-fit-snapped` | yes | `zoom-to-fit` over the focused canvas window's snap cluster, with no widget and no screen-pinned window in it; see [SIZES.md](SIZES.md#zoom-to-fit-snapped) |
| `grow-window <dir>`, `shrink-window <dir>`, `fit-window`, `fit-window-snapped`, `fill-window` | with the capability | they deliver a size to a native window, which a shell that performs resize effects can do, as every normal run's does. Until the shell has sent `native_resize_capability` they are refused like the row below; after it they run on the focused canvas window, pass over a widget and a screen-pinned window, and the reply may also carry `transaction` and `effect`. See [SIZES.md](SIZES.md) |
| `toggle-fullscreen` | with the capability | it resizes a window to its output, through the same gate: [FULLSCREEN.md](FULLSCREEN.md). Without it, parsed with upstream's argument rules, then refused |

[NAVIGATION.md](NAVIGATION.md#window-navigation-actions) describes the four
window navigation actions, [CONFIG.md](CONFIG.md#actions-that-run-now) the
nudge, exec and reload actions, [Outputs](CONFIG.md#outputs) the two output
actions, [Keyboard layouts](CONFIG.md#keyboard-layouts) `switch-layout`,
[LIFECYCLE.md](LIFECYCLE.md#actions-and-ipc) the close and suspend actions,
[MOTION.md](MOTION.md#cursor-edge-pan) `toggle-cursor-pan`,
[GESTURES.md](GESTURES.md#set-trackpad) `set-trackpad` and
[RULES.md](RULES.md#actions) the bookmark move and the pin toggle, with what
every action here does when the focused window is a widget or screen-pinned.
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

There is no canvas-point jump: upstream removed `go-to X Y` before the pinned
commit, and here it is an unknown action like any other (`unknown action:
go-to`). Save the point as a bookmark and use `go-to-bookmark <name>`.
`resize-window` and `resize-window-snapped`
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
[`tap`](CONFIG.md#tap-bindings), which runs its chord's the same way,
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
convention, a **center** point with **Y up**. It never stores zoom. Names are
unrestricted strings, as upstream's are.
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
- The map is saved under the top-level `bookmarks` key of the save file, which
  is always written and holds an empty map while there are no bookmarks. A file
  without the key is refused whole.
- Numbers are parsed exactly (`serde_json`'s `float_roundtrip` feature, enabled
  in this crate's manifest): the coordinate a request sets is the one stored,
  saved and read back after a reload. Without it a fractional coordinate could
  land one unit in the last place away, which the first live run showed.
- Each output has an **active bookmark**: the visible bookmark nearest its
  usable center, from `driftwm_core::canvas::active_bookmark` with upstream's
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

`reply` is upstream's `Reply`: `{"Ok":<Response>}` or `{"Err":"message"}`. One
request has no reply yet when `ipc` returns: an accepted `Screenshot` answers
`"reply": null` with a `{"op":"screenshot",…}` effect, and its reply is what
`screenshot_result` returns once the shell has rendered
([RENDER.md](RENDER.md#screenshots)). The shell must write nothing to the
client for a `null`.
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
  **whole output** (`driftwm_core::canvas::viewport_center` / `camera_for_center` over the
  `screen_bounds` size), as upstream's `camera_center` is.
- Bookmarks, zoom anchoring and the focus visibility test use the **usable
  rectangle**, as upstream's `usable_center_screen` and usable area are.

A viewport centered on a canvas point whose Y is 0 reads `-0.0`, and the
client prints `0 -0` after `camera 0 0`. That is upstream's own: its
`viewport_center` (`src/canvas.rs`, `driftwm-core`'s here) negates the Y-down
center, the negation of a positive zero is a negative one, and its client
prints the pair with `{x} {y}` (`src/ipc/client.rs`), which writes the sign.
Upstream's arithmetic, compiled apart, printed `0 -0` for the same request.
Nothing here normalises it.

Only `screen_bounds`, the navigation context and world rectangles are read, and
of `screen_bounds` only the size enters any camera or window position. Its
origin is read in three places: the adjacency of outputs, the screen point of
a `warp_pointer` effect, and a `from_screen` screenshot region, which is given
in global screen points and is read through the `screen_bounds` of the output
under it. Observed and original native rectangles never enter the math.

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
| `"Cursor"` | yes, and a `pointer` | `Cursor{x,y,output}` (v0.21.0): the pointer in the global output layout, the space `screen_bounds` and a `from_screen` screenshot region are in (logical points, Y down), and the stable id of the request's output. The controller keeps no pointer: the shell sends the point with every `ipc` command, and without one the reply is `Err("no pointer")`; then `Err("no output")` without an active output and `Err("unknown output")` for an id that is not registered, upstream's order. Never `dirty`, never an effect. |
| `{"Camera":null}` | yes | `Camera{x,y}`: the output's viewport center. |
| `{"Camera":[x,y]}` | yes | Flies the viewport center to the point at the current zoom and echoes the request. Refuses non-finite numbers, and (v0.21.0) a coordinate past ±1e9: `camera coordinates must be within ±1e9`, before a fullscreen is ended or anything touched. Like `go-to-bookmark` it writes only the camera target; unlike it, a zoom-to-fit return stays armed, as upstream leaves it. |
| `{"Zoom":null}` | yes | `Zoom(z)`: the current zoom. |
| `{"Zoom":z}` | yes | Clamps to `[dynamic minimum, 1]` (the minimum `zoom_out` uses), flies there anchored on the usable center and replies with the clamped value. Refuses non-positive numbers. No snap to 1 and no "never zoom in" rule: the value is explicit. |
| `{"Focus":null}` | no | `Focused({id,app_id})` for the logical focus, or `Focused(null)`. |
| `{"Focus":<selector>}` | yes | Logical focus and raise, plus upstream's camera rule: a frame already wholly inside the usable area is only focused; a window with a bound source is navigated to at zoom 1, or at the current zoom when `zoom.reset_on_activation` is off, exactly as `navigate_window` does; a detached placeholder is panned to at the current zoom, as upstream's `reveal_suspended` does for a stand-in. `effects` holds the focus effect when the window has a bound source; `dirty` is true because focus and stacking are saved. A pinned window is raised and focused without a navigation; a widget is refused, `window #N is a widget and cannot be focused`. |
| `{"Move":{window?,to?}}` | no | Without `to`: `Position{x,y}`, the frame's center. With `to` (v0.21.0: a coordinate past ±1,050,000,000 is refused first, `coordinates must be within ±1050000000`, before the selector is resolved): a logical world move that puts the frame's top-left on whole points and keeps its size; `dirty` is true. A bound source is raised even if its position is unchanged, without changing focus or any camera; a detached placeholder keeps its stacking. A widget is raised within the widget stack and stays below ordinary windows. Refused while a drag or resize gesture is installed, while a native resize transaction on that window is live, and when the destination frame would leave the `i32` range (`window geometry exceeds integer range`). A pinned window and a fullscreen one read and refuse the write: `this window has no canvas position to move: it is pinned, fullscreen, or not on screen yet`. A widget is moved by nothing else. |
| `{"Resize":{window?,to?}}` | no | Without `to`: `Size{width,height}`. With `to`: a non-positive size gets upstream's `size must be positive`, then (v0.21.0) a side past 32767 gets `sizes must be at most 32767`, then a pinned window, a widget and a fullscreen window get upstream's `this window has no canvas size to set: it is pinned, fullscreen, a widget, or not on screen yet`, with or without the capability, and are not raised: upstream's `cmd_resize` refuses them ahead of its grab test and its raise. For a canvas window, until the shell has sent `native_resize_capability`: `Err`, `resize is not implemented on macOS yet: native layout resize is not available`. With the capability: upstream's center-preserving resize, `Size` echoing the size asked for, and a reply that may carry `transaction` and `effect`; the window is raised, as upstream raises a client, and is handed no focus, with `dirty` when that changed the stacking, and a request identical to the one last asked changes nothing; see [SIZES.md](SIZES.md#ipc-resizewindowto). |
| `{"Opacity":{window?,value?}}` | no | Without `value`: `Opacity(n)`, what the window is drawn at. With one in `[0, 1]`: pins it until the window is gone, never `dirty`. Live windows only. [RULES.md](RULES.md#ipc). |
| `{"Pin":{window?,value?}}` | for a pin, when no output shows the window | Without `value`: `Pin(bool)`. With one: `toggle-pin-to-screen` as a bool, for any live window; `dirty` when it changed. [RULES.md](RULES.md#ipc). |
| `{"Action":"…"}` | per action | Runs the `action` command's handler. `Ok` whenever it runs, even with no effect; every refusal above is an `Err` reply. |
| `{"Bookmark":{name?,to?,delete?}}` | no | Upstream's four forms: list (`Bookmarks{…}`, sorted by name), get and set (`Bookmark{x,y}`), delete (`Ok`). Set and delete report `dirty`. Errors are upstream's: `no bookmark named '…'`, `bookmark delete requires a name`, `bookmark delete does not take coordinates`, `bookmark coordinates require a name`, `bookmark coordinates must be finite`, and (v0.21.0) `bookmark names are at most 256 bytes`, `bookmark coordinates must be within ±1e9` and, for a new name once 256 are held, `at most 256 bookmarks can be set; delete one first`. The `set-bookmark` action takes the same bounds and, as upstream's, drops a refusal without a word. |
| `"DebugCounters"` | no | Sizes of the controller's own collections, keyed by field name. Unstable. |
| `{"Close":<selector or null>}` | no | Upstream's `cmd_close`. A live window: `Ok`, `effects` is one `close_window`, and the close is marked real so `session.suspend_on_close` leaves no stand-in. Else a detached placeholder: dismissed, `Ok`, `dirty`. Else the selector's `Err`. |
| `{"Suspend":<selector or null>}` | no | Upstream's `cmd_suspend`. A live window is focused first if it is not (a focus effect, `dirty`, no camera move), then the `suspend-window` action runs: `Ok`, `effects` ends with one `close_window`. A detached placeholder: `Err("window is already suspended")`. |
| `{"Relaunch":<selector or null>}` | no | Upstream's `cmd_relaunch`. A detached placeholder: `Ok`, `effects` is one `launch`, and the next window of that app to appear within thirty seconds takes the placeholder's slot; while that relaunch is pending the request is `Ok` with no effect, upstream's no-op. Anything else: `Err("no suspended window matching selector")`. A placeholder without a bundle identifier: `Err("the app has no bundle identifier to relaunch")`. |
| `{"Layout":{"short":false}}` | no | `Layout(name)`: the display name of the keyboard layout the shell last reported with [`layout_changed`](CONFIG.md#keyboard-layouts), or `""` before any report. |
| `{"Layout":{"short":true}}` | no | `Layout(short)`: its short code, or the display name when the code is empty, as upstream falls back. |
| `"Subscribe"` | no | `Ok`, and the effect `{"op":"subscribe","line":…}` carrying the current snapshot. See [Event stream](#event-stream). With an `output` that is not registered: `Err("unknown output")`, as `State`. |
| `{"Screenshot":{target,scale,path}}` | per target | Upstream's `cmd_screenshot` up to the render. Refused with upstream's texts in upstream's order; otherwise `"reply": null` and `effects` is one `screenshot` request carrying the resolved canvas region and pixel size. The shell renders, calls `screenshot_result`, and writes what that returns as the reply line. See [RENDER.md](RENDER.md#screenshots). |

A missing output where one is needed is `Err("no active output")`; an id that is
not registered is `Err("unknown output")`. Camera and zoom writes reject with
`navigation during active gesture` while a gesture is installed.

A selector is upstream's: a JSON number is an Infinify logical window id, exact;
a JSON string is a case-insensitive substring of the bundle id, which passes
over widgets as upstream's does: only an id reaches one. Among several
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
`fullscreen` lists one `{id, output, app_id, title, pid}` per fullscreen output,
and such a window is left out of `windows`: [FULLSCREEN.md](FULLSCREEN.md).
`layers` and `canvas_layers` are always empty: neither exists here.

- `pinned`: the screen-pinned windows of the connected outputs, as upstream
  lists them: `id`, `output` (the stable id), `app_id`, `title`, the
  `position` and `size` a `pinned_to_screen` rule takes, and `pid`, sorted by
  output and position.
- `pid` (v0.21.0), on a `windows`, `pinned` and `fullscreen` entry alike: the
  process that owns the window's bound native source, from the identity the
  shell attached it with (upstream reads the Wayland socket's credentials). It
  belongs to the process, not the window: every window of one app reports the
  same. A detached placeholder has no source and the member is left out, as
  upstream leaves it out for a stand-in and for a window whose client has just
  gone. It is last in an entry, after `mode`.
- `windows`: every Scene window that is not pinned, the focused one first and
  the rest in stage order (bottom to top, so widgets come first). `id` is the logical window id, `app_id` the bundle id,
  `title` the last attached title, `position` and `size` the frame as above.
  `suspended` is true for a window with no bound source: a detached placeholder
  is Infinify's stand-in. `is_widget` is the window's rule's. `mode` is
  upstream's `window_mode`: `"Normal"`, or `"Fit"` or `"Fill"` while the window
  holds a [fit or fill restore point](SIZES.md#mode), which it can only get
  once the shell has sent `native_resize_capability`. A pinned window is listed
  under `pinned`, which has no mode. The `msg` client prints `mode` with
  `--json` only.
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

Commands and arguments are upstream's ([`docs/cli.md`](https://github.com/malbiruk/driftwm/blob/df3de27b26c7998e8a460cffd8a4925cbed3a322/docs/cli.md)): `state`, `subscribe`,
`focus [APP_ID] [--id ID]`, `move [X] [Y] [--id ID]`,
`resize [WIDTH] [HEIGHT] [--id ID]`, `close`, `suspend` and `relaunch`
`[APP_ID] [--id ID]`, `opacity [VALUE] [--id ID]`, `pin [on|off] [--id ID]`,
`camera [X] [Y]`, `zoom [LEVEL]`, `bookmark [NAME] [X] [Y] [--delete]`,
`layout [--short]`, `cursor`, `action <SPEC>...`,
`screenshot [--scale S] [-o PATH] [window [APP_ID] [--id ID] | all | region X Y W H [--from-screen]]`
and `debug-counters`. `cursor` prints `X Y OUTPUT`, the pointer in the global
output layout and the stable id of the output it is on. Negative numbers are values where upstream allows them
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
- `screenshot` builds upstream's request (an absolute path) and prints the path
  of the reply. For `-o -` (v0.21.0) the client first reserves a file of its own,
  created new with mode 0600 in the directory of the socket (which the app only
  serves from when it is yours and not writable by group or others), puts that
  path in the request, relays the file's bytes to stdout whatever path the reply
  names, and deletes it when it is done, even on failure. Upstream reserves it
  under `$XDG_RUNTIME_DIR/driftwm`, which macOS has no equivalent of, and no
  longer reads a path from the reply either. A refusal is printed like any other
  `Err` reply.

## Differences from upstream

- Camera and zoom writes, and `go-to-bookmark`, reject during a drag or resize
  gesture, as every navigation command here does. Upstream has no such gate.
- What ends a fullscreen, the `Camera` and `Zoom` writes, `Suspend` and most
  actions among it, is [FULLSCREEN.md](FULLSCREEN.md#leaving). `Close` ends
  none, as upstream's `cmd_close` ends none.
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

## v0.21.0 hardening

DriftWM v0.21.0 (<https://github.com/malbiruk/driftwm> @
`df3de27b26c7998e8a460cffd8a4925cbed3a322`) "hardens driftwm against
misbehaving clients". What applies
to a Mac app is here; what does not is listed after the table. Upstream's tests
are compositor integration tests over Wayland clients and are not run; each row
names the Infinify test that covers it, and says plainly what ran.

| v0.21.0 item | Upstream source | Here | Covered by |
| --- | --- | --- | --- |
| A request is at most 1 MiB (4 KiB upstream) | `src/ipc/mod.rs` `MAX_COMMAND_SIZE` | `DWIPCMaxLine = 1 MiB` in `native/desktop/ipc-server.m`; the C ABI's `MAX_REQUEST_BYTES` is 1 MiB | `tests/e2e/ipc-limits.sh`: a 200 KiB and a 900 KiB line are answered, one past 1 MiB is hung up on without a reply |
| At most 1024 connections; one past it is told why in one line and closed | `MAX_CONNECTIONS`, `refuse_connection` | `DWIPCMaxConnections = 1024`, `refuse()`: `{"Err":"1024 IPC connections are already open"}`. The listen backlog is 128 (what std's `UnixListener::bind` ends up with on macOS: it passes -1 and the system caps it at 128), so a burst is not refused while it is accepted. A connection takes a descriptor, so the app raises its soft open-file limit at launch (`raiseOpenFileLimit` in `main.m`: to `kern.maxfilesperproc`; macOS starts a process at 256) | `tests/e2e/ipc-limits.sh`: 1024 held connections, the next one reads the refusal line and EOF, a freed slot is reused |
| Only the bytes just read can complete a request, so a long partial line is not rescanned | `serve_connection` | `-[DWIPCServer read:]` returns at once on a read with no newline | `tests/e2e/ipc-limits.sh`: a 256 KiB line written in 4 KiB pieces completes |
| The writes of one reply share one deadline, from when the reply is ready; a reader that stalls is dropped | `write_line`, `wait_writable`, `WRITE_TIMEOUT` | already so: `writeBytes` in `ipc-server.m` polls to one monotonic one-second deadline for the owed events and the reply together | not newly covered; the stalled-reader drop was never run (see below) |
| One read per wakeup | `serve_connection` | already so: one 4096-byte read per dispatch event, and a connection is read again only after its reply | by construction |
| Window positions within +-1,050,000,000, `msg camera` and bookmarks within +-1e9, sizes at most 32767 | `src/ipc/mod.rs` `check_point`, `check_size`, `cmd_camera`; `src/state/session_store.rs` `POSITION_LIMIT`, `CAMERA_LIMIT`, `valid_canvas_point`, `within_window_range`, `bookmark_problem` | `ipc.rs` (`check_point`, `check_size`, `cmd_camera`, `cmd_bookmark`), `storage.rs` (the constants and predicates), `render.rs` (a screenshot region, and a `from_screen` one that lands past the window range zoomed out: `region lies past the canvas range`) | `tests/ipc_flow.rs` `requests_are_bounded_as_v0_21_0_bounds_them`, `a_screenshot_region_is_bounded_before_a_pixel_is_drawn`, the Move arm of `move_resize_and_focus_address_logical_windows` |
| The bookmark registry holds at most 256 names of at most 256 bytes | `MAX_BOOKMARKS`, `MAX_BOOKMARK_NAME`, `DriftWm::set_bookmark` | `Controller::store_bookmark` (`storage.rs`), used by `Bookmark` and by `set-bookmark`, which drops a refusal as upstream logs it | `tests/ipc_flow.rs` as above |
| A saved bookmark registry is cut to what `set` would accept, a saved camera past the window range is not restored | `bounded_bookmarks`, `valid_camera_seed` | `Controller::load`: out-of-bounds bookmarks are dropped one by one; such a camera is replaced by the origin at zoom 1 | `tests/hardening_flow.rs` `restoring_a_scene_keeps_only_the_bookmarks_a_set_would_have_accepted`, `restoring_a_scene_keeps_at_most_256_bookmarks`, `a_saved_camera_past_the_window_range_is_not_restored` |
| A stand-in is capped at 16384 px (`MAX_BUFFER_EXTENT`); a larger saved one is dropped on restore | `SizeConstraints::for_suspended`, `standin_body_rect`, `valid_entry_geometry`, `suspended_entry` | a window that becomes a stand-in is cut to 16384 on each side keeping its top-left (`cap_standin`, `lifecycle.rs`); a saved slot of any window whose side is past 16384 or whose top-left is past the position limit is dropped with its metadata, stand-in mark and pin, and the focus is left empty if it was the focused one (`Controller::load`) | `tests/hardening_flow.rs` `a_stand_in_is_cut_to_the_largest_chrome_buffer_and_keeps_its_top_left`, `restoring_a_scene_drops_the_slots_a_stand_in_could_not_be_or_that_lie_past_the_window_range` |
| Session and state files are owner-only | `src/session.rs` | the scene file is written through a new 0600 file and renamed (`Controller::save`); the sockets and `.infinify-lock` files are 0600 and the support directory 0700 when the app creates it | `tests/hardening_flow.rs` `the_scene_file_is_owner_only_and_leaves_no_temporary_behind`; the sockets and locks by `tests/e2e/ipc-limits.sh` |
| A screenshot is written to a temporary file beside its target and renamed into place | `src/render/screenshot.rs` `write_png` | `DWWriteScreenshotPixels` (`screenshot-writer.m`): `.NAME.PID-N.tmp`, `O_EXCL`, written, `rename`; removed on any failure | `tests/e2e/ipc-limits.sh` (a symbolic link at the path is replaced, its target untouched; a directory at the path leaves no temporary) |
| `screenshot -o -` goes through a private file the client reserves; nothing is written under `/tmp` | `src/ipc/client.rs` `StdoutCapture`, `edd108f` | see the `msg` client above | `tests/ipc_flow.rs` `screenshot_to_stdout_goes_through_a_private_file_the_client_reserved`; `tests/e2e/ipc-limits.sh` (stdout equals the file capture, nothing left behind) |
| A spawned app inherits no descriptor, neither `DRIFTWM_CONFIG` nor `RUST_LOG`, and gets the normal open-file limit back | `prepare_child`, `raise_nofile_limit`, `1a1bcf3`, `764abd6` | no descriptor is inherited (`POSIX_SPAWN_CLOEXEC_DEFAULT`, `POSIX_SPAWN_SETSID`); `execCommand` also drops `DRIFTWM_CONFIG`, `RUST_LOG` and every `INFINIFY_` variable from the environment it passes on (`INFINIFY_SOCKET` is put back, and an `[env]` entry still wins); after a raise, `sh` restores the original soft limit first (`ulimit -Sn`, because `posix_spawn` has no hook between fork and exec) | the wrapper's behaviour was run in isolation only (a child of `sh -c 'ulimit -Sn "$0"; exec sh -c "$1"' 256 …` reads 256 and its exit status 126 comes through); `main.m` itself compiles clean (`clang -fsyntax-only -Wall -Wextra -Werror`) and has not been run |
| `exec-terminal` and `exec-launcher` read `$TERMINAL` and `$LAUNCHER` from the config's `[env]` before the process environment | `detect_terminal`, `detect_launcher`, `child_var` | `from_environment` (`actions.rs`) | `tests/hardening_flow.rs` `exec_terminal_and_exec_launcher_read_the_config_env_before_the_process_env` |

Out of scope, with the reason (none of these has a Mac counterpart in this app):

- Activation tokens that expire after 10 seconds, are capped and spent on use
  (`xdg-activation`): a Wayland protocol; macOS has no such token.
- Gamma tables and virtual keymaps read only from regular files or memfds
  (`wlr-gamma-control`, `zwp_virtual_keyboard`): Wayland client protocols; the
  Mac's display gamma and keyboard stay macOS's (the parity README's host-owned
  decisions).
- A pen resting over a window cannot change the cursor drawn over the lock
  screen: the session-lock protocol; macOS draws its own lock screen.
- A dialog's modal hint only moves focus within its own app (`xdg-dialog`):
  there are no Wayland dialogs here; macOS sheets belong to their app.
- An oversized blur region or overcomplicated opaque region is ignored
  (`wl_surface` regions): no client sends regions here.
- GTK apps drop their title bar under `default_mode = "minimal"` and `"none"`
  (KDE server decorations): a Wayland protocol.
- The DRM error dump to `/tmp` is gone, the DRM, udev and winit backends,
  wlr-screencopy and ext-image-copy-capture fixes, the Wayland fractional scale,
  the TIFF wallpaper decoder abort and desktop entry reading: no such code path
  exists here (the wallpaper is `background-tiff.m`'s, and the app reads no
  desktop entries).
- Layer names written to the state file are sanitized: there are no layer
  surfaces and no state file of layer names.
- The flake and Home Manager module: Nix packaging of the Linux compositor.

Not done or not run: the shell's side was compiled and, for the socket server
and the screenshot writer, run headless (`tests/e2e/ipc-limits.sh`, 2026-10-29,
macOS 27.2, Apple Silicon); the stalled-reader drop was not exercised, the
raised open-file limit and the environment scrub were not run in the built app,
and `msg cursor` with a real pointer was not run: the app was not launched.
`/tmp` is still used by the owner-run native launcher
(`scripts/native-desktop-launcher.sh`: `mktemp -d /tmp/if-native.XXXXXX`, a new
mode-0700 directory holding the loader nonce and payload copy, which
`native/privileged/loader.m` validates by name); it is part of the privileged
loader's contract, which this change does not touch.

## Evidence and limits

`tests/ipc_flow.rs` drives the exported C ABI with upstream-shaped request JSON
and checks reply shapes and resulting controller state: the `State` shape,
camera and zoom round trips on outputs whose `screen_bounds` origin is not the
global origin and whose usable center differs from the output center, bookmark
set / go-to / list / delete and the save file's `bookmarks` key (a file without
it is refused whole), a camera read of `-0.0` for a viewport centered on Y 0, `Move` with its
range refusal, `Focus` of a bound window (zoom 1) and of a
placeholder (current zoom), every refused and unknown request against an
unchanged `snapshot`, and an accept / reject table for the action grammar. The window navigation actions, `pointer`, `held` and the cycle prelude
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
default-path resolution, and the `screenshot -o -` relay (it needs a server
that writes the file; it was run against the built app, see
[RENDER.md](RENDER.md#verification-boundary), where the bytes on stdout
equalled a file capture of the same target and no temporary file was left; the
relay flushes stdout itself, because this client is entered from C `main` and
no Rust runtime flushes it at exit). The shell's side of the stream is not
covered by these tests at all: its socket writes, its subscriber limit, how it
drops a peer that stops reading, and when it calls `state_event`. Two launches
of the built app on 2026-10-09, described in the
[shell notes](../../native/desktop/README.md), observed the
stream over the real socket (the ack and first line, one line per frame of a
flight and none while idle, no repeated line, the limit of eight, requests on a
subscribed connection, a clean end on exit); they left no saved evidence and
did not reach the stalled-subscriber drop. Upstream's own sources are not
executed: expected values are worked out from the adapted formulas, not from an
oracle build.

The tests are logical controller behavior only. Nothing in them opens a socket
in the app, registers a hot key, moves or focuses a native window, renders, or
captures.
