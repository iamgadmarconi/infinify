# Desktop controller ABI v1

`driftwm-desktop` builds an `rlib` and `libdriftwm_desktop.a`. Include
[`crates/desktop/src/driftwm_desktop.h`](../../../crates/desktop/src/driftwm_desktop.h) from the native shell.
The shell that links it is the Objective-C desktop in
[`native/app`](../../native/README.md): `./scripts/build-app.sh`
builds this crate (`cargo build -p driftwm-desktop --release`) and links the
static library into `target/app/Infinify.app`.
Use one handle per scene, with serialized access. The C boundary catches Rust
unwinds; it cannot protect against invalid pointers, use-after-free or OOM aborts.
`driftwm_desktop_clone` copies logical state into a separately owned handle,
which may move to a worker with exclusive access. Access the source exclusively
while cloning, then destroy each handle independently. The native scene writer
uses this to keep serialization and durable filesystem commits off the live
controller's main thread.
Always release returned strings with `driftwm_desktop_response_free`. A null
response indicates response construction failed. Null handles/requests produce
JSON errors; null destroy/free are no-ops.

Pass UTF-8 bytes (maximum 1 MiB), without requiring a trailing NUL:

```json
{"version":1,"command":{"op":"snapshot"}}
```

Successful responses are `{"version":1,"ok":true,"data":{...}}`; failures are
`{"version":1,"ok":false,"error":"..."}`. Every object rejects unknown fields.
Unsupported versions, duplicate schema fields, invalid numbers and bad geometry
are rejected. Rejected commands leave scene, bindings and gesture state unchanged.
Error messages are diagnostic strings, not stable error codes.

`snapshot`, `hit`, `input` and `resize_border` read the settled controller
directly, without cloning it or changing state. Mutating commands retain the
clone/apply/settle/commit transaction. Public `Controller::load` also normalizes
the loaded state before returning, including saved pins' snapping exclusions.
Expired lifecycle marks are removed before fullscreen/policy settlement, so
cleanup completes with the mutation that advances time instead of depending on
a later query. These source optimizations have not been benchmarked.

All rectangles are `{origin:{x,y},size:{width,height}}`, points are `{x,y}`.
Coordinates are logical points with top-left origin and Y down. Output bounds
and pointer positions are global screen points. The AppKit shell must convert
its bottom-left coordinates before calling. Buffer dimensions/crops are pixels.
Logical window/output IDs are unsigned 64-bit integers, allocated starting at 1.
Preserve them as integers in native code.

| `command.op` | Remaining command fields | Result data |
| --- | --- | --- |
| `register_output` | `stable_id` string, `screen_bounds` rect, optional `usable_rect_local` rect | `output` logical ID; the rectangle is the output's [usable area](NAVIGATION.md#the-usable-area), the whole output without one |
| `set_usable_area` | `output`, `usable_rect_local` rect | `{dirty}`; the output's usable area changed, and nothing else does. The shell sends no usable area, here or with `register_output` ([NAVIGATION.md](NAVIGATION.md#the-usable-area)) |
| `remove_output` | `output` | `{}`; camera retained by stable identity |
| `outputs_settled` | none | `{dirty}`; sent once every display is registered: a screen-pinned window whose output is missing moves to one that is connected ([RULES.md](RULES.md#wire-contract)) |
| `attach` | `identity`, `bundle_id`, `title`, `buffer:{width,height}`, `source_rect`, optional `logical_id`, optional `world_rect`, optional `output`, optional `pointer` | `window` logical ID; for a new window also `adopted`, `effect`, `navigation`, `dirty`, and `transaction` with a one-entry `effects` when its rule's `size` began a size transaction ([RULES.md](RULES.md#a-rules-size)) |
| `window_closed` | `window`, `identity`, optional `output` | `{standin, effect, navigation, dirty}` |
| `retitle` | `window`, `identity`, `title` | `{dirty}` |
| `adoption_complete` | optional `present`, an array of `{bundle_id, title}` | `{dropped, standins, dirty}` |
| `observe` | `window`, `identity`, `source_rect`, `buffer` | `{}`; never changes world geometry |
| `remove_source` | `window`, `identity`, `keep_placeholder` boolean | `{}` |
| `forget` | `window` | `{}`; removes source and world placeholder; a placeholder it removes is logged as a `standin_dismiss` ([EFFECTS.md](EFFECTS.md#lifecycle-events)) |
| `pan` | `output`, `screen_delta` point, optional `time_ms` and `source` | `{}`; positive X reveals world to right; with `time_ms` it feeds momentum |
| `pan_end` | `output`, optional `time_ms` | `{needs_frames}`; launches momentum |
| `pointer` | `output` or null, global `screen` point | `{needs_pointer, needs_frames}`, and `dirty` with `effect` when sloppy focus followed a moved view (v0.20.0); for cursor edge pan and that pull |
| `zoom_by` | `output`, global `anchor` point, `delta`, `source`, optional `phase` | `{navigation, needs_frames}`; wheel or pinch zoom at the config's speeds |
| `zoom` | `output`, `zoom` in `[0.001,1]`, global `anchor` point | `{}`; anchor world point stays fixed |
| `focus` | `window` | `effect` or null; raises logical world z-order |
| `activate` | `window`, `output` or null, `cause: click / click_release / native`, optional `identity`, `generation` | `effect` or null (absent for `click_release`), `navigation` or null, `dirty`; see [NAVIGATION.md](NAVIGATION.md#activate) |
| `clear_focus` | none | `{dirty}`; no window holds logical focus |
| `hit` | `output`, global `screen` point | `hit` object or null, and `pick`; the hit says whether the window is a `widget` or `pinned`, and whether it is a `pick` target |
| `input` | `output`, global `screen` point, expected `identity` | same hit object; rejects absent/unbound/stale target, and a pick target (never a widget or a pinned window) |
| `hover` | `output`, global `screen` point, optional `time_ms` | `{dirty, pick, hit, forward}`, and `effect` when sloppy focus moved the focus; see [POINTER.md](POINTER.md#hover) |
| `pick` | `window`, `output` | `{effect, navigation, dirty}`; a left click in pick mode |
| `pointer_nearest` | `output`, global `screen` and `start` points, optional `held`, optional `focus` boolean | `{navigation, effects, dirty}`; a press bound to the mouse action `center-nearest`, or with `focus` (v0.20.0) to `focus-nearest` |
| `begin_drag` | `window`, `output`, optional `group` boolean (default false) | `{effect}`: the window is raised and focused ahead of the grab, as upstream's move press does, and `effect` is the focus request `activate` returns, or null for a window without a source; a screen-pinned window is dragged in screen space ([RULES.md](RULES.md#dragging-a-pinned-window)) |
| `begin_resize` | `window`, `output`, `edges`, optional `group` boolean | `{effect}`, as `begin_drag`: raised and focused first |
| `gesture_to` | total `screen_delta` from gesture start, optional global `pointer` point | `{needs_frames}`; a drag's `pointer` arms edge pan |
| `end_gesture` | none | `{}` |
| `gesture_begin` | `kind`, `fingers`, `modifiers`, `context`, `output`, global `pointer` point, optional `doubletap`, `time_ms` | `{gesture, fired, note, navigation, effects, dirty, needs_frames, trackpad}` |
| `gesture_update` | optional `dx`, `dy`, `scale`, `rotation`, `held`; `time_ms` | the same |
| `gesture_end` | optional `cancelled`, `held`; `time_ms` | the same |
| `snapshot` | none | `outputs`, `windows`, `focus` (`intent`, `observed_native`, `pending_effect`, `last_result`, `history`, `cycle`, `release_pending`; see [FOCUS.md](FOCUS.md)), `pass_keys` ([RULES.md](RULES.md#pass_keys)), `placements`, `lifecycle`, `lifecycle_events` ([EFFECTS.md](EFFECTS.md#lifecycle-events)), `render`; each output with `pick` ([POINTER.md](POINTER.md#pick-mode)) and `fullscreen` ([FULLSCREEN.md](FULLSCREEN.md#wire-contract)), each window with its `widget`, `pinned`, `rule` and `mode` ([SIZES.md](SIZES.md#mode)), each placement with `pinned`, `widget` and `opacity`, and both with what the window is drawn with (`kind`, `decoration` and the rest of [RENDER.md](RENDER.md#placements)) |
| `screenshot_result` | `path`, `width`, `height`; or `error` | `{reply}`: upstream's reply to the client that asked for the screenshot |
| `save` / `load` | explicit caller `path` string | `{}` |
| `load_config` | `path` string or null | `{path, exists, errors, warnings, dirty, effects, focus_follows_mouse}` |
| `set_platform` | `super` chord | `{super}` |
| `bindings` | none | key bindings as macOS chords, the tap bindings as the modifiers to watch (`taps`), the `cycle_hold` modifiers, and each output's hot corners |
| `mouse_binding` | `trigger` (a button, `scroll`, or the wheel notch `wheel_up` / `wheel_down`), `source`, `modifiers`, `context`, optional `window`, optional `pick` boolean | `{binding}` or `{binding: null}`; `{binding: null, passed: true}` when the window's `pass_mouse` claims the trigger, which a pick target never does ([RULES.md](RULES.md#pass_mouse)) |
| `hot_corner` | `output`, `corner`, optional `pointer`, `held` | `{navigation, effects, dirty}` |
| `tap` | `modifiers`, `output` or null, optional `pointer`, `held` | `{navigation, effects, dirty}`, an `action` reply: the [tap binding](CONFIG.md#tap-bindings) on a bare modifier chord that was pressed and released alone |
| `native_resize_capability` | `enabled` boolean | `{}`; the shell performs resize effects in this run, and a size is settled by the native read alone: see [SIZES.md](SIZES.md#the-gate) and [NATIVE_RESIZE.md](NATIVE_RESIZE.md#readback-mode) |
| `layout_changed` | `name`, `short`, `index`, `count` | `{}` |
| `state_event` | `output` or null | `{line}`: the State event line, or null when unchanged |

See [focus/cycle commands](FOCUS.md) for the focus ABI and
[normal-window navigation](NAVIGATION.md) for camera commands, runtime snapshots,
and the native frame-clock contract. [Camera motion](MOTION.md) covers timed
pans and momentum, edge pan, cursor edge pan and `zoom_by`.
[Actions, bookmarks and IPC](IPC.md)
covers the `action`, `ipc` and `state_event` commands, the saved bookmark map,
the event stream, and the exported `driftwm_desktop_msg` client.
[Configuration](CONFIG.md) covers the seven commands from `load_config` to
`layout_changed`: DriftWM's TOML file, what of it is applied, the binding map,
tap bindings, outputs, hot corners, keyboard layouts, autostart, and what
stands for upstream's Linux commands. [Window lifecycle](LIFECYCLE.md) covers a window
that appears or closes by itself: adoption, placement, stand-ins,
`window_closed`, `retitle`, `adoption_complete` and the close, suspend and
relaunch actions, and what a report that is repeated, late or early is
answered ([event delivery](LIFECYCLE.md#event-delivery)).
[Window rules](RULES.md) covers `[[window_rules]]`, widgets and screen-pinned
windows: what a rule does to a new window, the order `placements` and `hit`
follow, what every navigation, gesture and output action does with a widget or
a pinned window, `toggle-pin-to-screen`, `move-to-bookmark`, IPC `Pin` and
`Opacity`, the `pass_keys` and `pass_mouse` rules, and the drag of a pinned
window by the move binding and the move gesture.
[Rendering](RENDER.md) covers what the shell's compositor draws from: the
snapshot's `render` block, what each placement is drawn with (the rule its
window mapped with, the layer and the space it is drawn in), and the
`msg screenshot` flow that ends in `screenshot_result`.
[Effects](EFFECTS.md) covers what DriftWM's blur, window animations and error
bar are drawn from: the `[effects]` table and the error messages in `render`,
each window's `decoration.blur`, and the snapshot's `lifecycle_events`.
[Trackpad gestures](GESTURES.md) covers `gesture_begin`, `gesture_update` and
`gesture_end`: a libinput-shaped swipe, pinch or hold dispatched against the
`[gestures]` tables. They are apart from `begin_drag`, `begin_resize`,
`gesture_to` and `end_gesture`, the pointer's drag and resize below.
[Pointer policy](POINTER.md) covers `hover`, `pick` and
`pointer_nearest`: pointer motion, `focus_follows_mouse`, the pick mode of
`zoom.interact_min` and the pointer's `center-nearest`.

## macOS modifiers

Bindings are written in upstream's modifiers and mapped to a Mac keyboard:

- `ctrl` is Control, `alt` is Option, `shift` is Shift.
- `logo` (`super`, and `mod` when `mod_key = "super"`, upstream's default) is a
  physical chord: Command unless `set_platform` chooses another subset of
  `ctrl`, `alt` and `cmd`. The Mac adapter also adds Super+Tab and F3 as overview toggles; explicit user bindings and disabled defaults take precedence.
- A binding that holds `logo` and a modifier the chord already contains is
  displaced so it stays distinct: `ctrl` becomes Command and `alt` becomes
  Command+Shift. With `super = "ctrl+alt"`, `mod+ctrl+Right` is ⌃⌥⌘→ and
  `mod+alt+Right` is ⌃⌥⇧⌘→. A chord that contains Command leaves nothing to
  displace to, and such a binding is skipped with a warning.
- `mod3` has no macOS equivalent: such bindings are skipped with a warning.
- Two bindings on one physical chord: the first by upstream combo text keeps
  it, the other is reported. Control+Option+Escape is the shell's exit chord
  unless a binding claims it.
- A bare modifier chord (`"alt+shift" = "switch-layout next"`) is upstream's
  tap binding: it takes the same mapping, is listed under `taps`, and runs
  through `tap` when the shell sees the chord pressed and released alone.

[CONFIG.md](CONFIG.md) has the key identity rules and upstream's default table
as it lands on a Mac.

`edges` is `left`, `right`, `top`, `bottom`, `top_left`, `top_right`,
`bottom_left` or `bottom_right`. One gesture is active per controller. Motion
uses gesture-start zoom and real canvas snapshot/hysteresis/group semantics.
The snap distance is 24 screen points, break force 32 screen points, and gap
12 world points unless the [config](CONFIG.md)'s `[snap]` table says otherwise.
Distance and break force use current output zoom on each update;
displacement still uses gesture-start zoom. See the [snapping contract](../canvas/SNAPPING.md)
for the verified algorithm scope and remaining coordinate/rounding differences.
Resize changes the world representation; native resize delivery
is the host's responsibility. No command itself changes a native window.
For observed native resizing, the separate
[native resize transaction](NATIVE_RESIZE.md) keeps proposals apart from committed
geometry, coalesces effects, handles late results and gates stale capture/input.
Its native shell connection and actual frame-freshness proof remain unfinished.
[Window sizing actions](SIZES.md) covers `grow-window`, `shrink-window`, IPC
`resize`, `fit-window`, `fit-window-snapped`, `fill-window` and
`zoom-to-fit-snapped`: an `action`, `hot_corner`, `tap`, `ipc` or `gesture_*` reply
that begins a size transaction also carries its `transaction` and `effect`, and
every `snapshot` window has a `mode`. They act on canvas windows: what each
does beside a widget, a screen-pinned window, a window rule's `size` and pick
mode is [there](SIZES.md#widgets-screen-pinned-windows-and-rules) too.
[Fullscreen](FULLSCREEN.md) covers `toggle-fullscreen` and a rule's
`fullscreen`, behind the same gate: what a fullscreen output places and hits
(`outputs[].fullscreen`, the one placement with `fullscreen: true`, the
`fullscreen` mode), what ends a fullscreen and what that restores, and the
size an exit owes, which leaves with the next reply the shell performs sizes
from.

A source identity is `{pid,birth_sec,birth_usec,wid,owner?}`; `owner` optionally
records the WindowServer connection and is compared exactly, including presence.
The PID must be positive, birth seconds positive, microseconds in `[0,1000000)`,
and window/owner numbers nonzero. These checks only validate the observation's
shape. **The native caller must freshly validate the actual process birth,
window ownership and optional connection immediately around native delivery.**
A saved binding never authorizes native input. `input` checks identity equality
with the currently attached source; it does not deliver an event.

`attach` with a `world_rect` creates a new world window with that frame. A
supplied `logical_id` explicitly rebinds an existing unattached placeholder;
`world_rect` is then forbidden, preserving saved geometry. Both are the caller's
choice and nothing is matched or focused. With neither, a window has appeared by
itself: it takes over a waiting placeholder of its app or is placed by the
config's `window_placement`, as [LIFECYCLE.md](LIFECYCLE.md) describes, and
`source_rect` gives the world frame its size only. A PID is never matched.
Existing live bindings must first be detached before replacing their identity.

Each placement is a separate `(window,output)` instance, ordered bottom-to-top
within each output. Fields: `screen_rect` (full projection), `clip_rect` (visible
screen bounds), `world_local_crop`, `buffer_crop` (pixel crop, null for detached
placeholders), `source` (null or fresh ephemeral observation), and what it is
drawn with (`kind`, `focused`, `title`, `app_name`, `launching`, `world_rect`,
`decoration`, see [RENDER.md](RENDER.md#placements)), which each `windows`
entry carries as well. Source includes
`identity`, `buffer`, `original_rect`, and `observed_rect`. Native moves update only
`observed_rect`; world resizing scales the entire observed source into the world
rectangle. Crops and input therefore scale proportionally between these spaces.

Hit objects contain `window`, `output`, `identity`, `local` (observed native
window-local logical points), `buffer_local` pixels, `native_screen`, and
`requires_native_revalidation:true`. Hits use topmost world z-order. An unbound
placeholder blocks input with an error rather than clicking through it.

Saves contain scene geometry, app bundle/title metadata, which placeholders are
stand-ins, and cameras keyed by stable display identity. They contain no PID,
window number, process birth, connection, capture buffer, credentials, or gesture. Reload retains unattached
world placeholders and detached camera records; the shell must register actual
connected displays, then explicitly attach selected fresh sources. Output IDs
and cameras survive disconnect/reconnect and restart. Writes use a private
sibling temporary file, fsync, atomic rename and parent-directory sync. A directory
sync error can be reported after the rename committed. Parent directories must
already exist. Loads are bounded at 32 MiB and never modify the input file.

Verification. One test target per area lives in `crates/desktop/tests/`, each
driving the controller through JSON and the exported C ABI; run the targets of
the files you change, not the whole suite:

```sh
cargo test -p driftwm-desktop --test controller_flow --locked
cargo clippy -p driftwm-desktop --all-targets -- -D warnings
cargo fmt -p driftwm-desktop --check
```

The targets are `config_flow`, `controller_flow`, `effects_flow`,
`focus_cycle_flow`, `focus_nearest_flow`, `fullscreen_flow`, `gesture_flow`,
`hardening_flow`, `interact_min_flow`, `ipc_flow`, `lifecycle_flow`,
`motion_flow`, `native_resize_flow`, `navigation_actions_flow`,
`navigation_flow`, `passthrough_flow`, `platform_actions_flow`, `pointer_flow`,
`render_flow`, `rules_flow`, `sizes_flow`, `snap_actions_flow`,
`usable_tap_flow` and `view_actions_flow`. Each document in this directory names
the ones that cover it in its "Evidence and limits" or "Verification boundary"
section.

These scenarios prove controller behavior through JSON and the exported C ABI.
They do not prove captured pixels, drawn frames, written screenshots, usable
compositing or native input delivery.

## Outputs

A normal run of the shell is the desktop, not an app in a window:
`register_output` carries each display's whole rectangle, menu bar and Dock
included, and with `--windowed` the whole window. `screen_bounds` is whatever
rectangle the shell names, and the usable area is the whole of it unless the
registration, a `set_usable_area` or a `set_navigation_context` names a
smaller one, which the shell never sends
([NAVIGATION.md](NAVIGATION.md#the-usable-area)). What follows from the larger
rectangle is described where it applies: [hot corners](CONFIG.md#hot-corners),
[cursor edge pan](MOTION.md) and the environment of a run
[started at login](CONFIG.md#started-at-login).

## Behaviour source

The desktop controller follows DriftWM v0.21.0
(<https://github.com/malbiruk/driftwm> @
`df3de27b26c7998e8a460cffd8a4925cbed3a322`). Its parser, defaults and snapping
stops come from `driftwm-core`, which carries that commit's code
([PORT.md](../core/PORT.md#update-to-v0210)); the controller adaptations are
named in each source file's header, and a doc here that still cites
`352333a8fa1b22171492d4b71a54102045c9a19d` names the commit that part was
adapted at, which was re-read only where the v0.20/v0.21 changes touch it. The status of each
upstream behaviour is tracked in [docs/parity](../../parity/README.md).

Left out because they exist only for the Wayland or Linux stack: the KDE
server-decoration protocol (GTK header bars under `[decorations] default_mode`),
activation-token expiry, gamma tables and virtual keymaps from memfds, the
wlr-screencopy region fix, ext-image-copy-capture offsets, the monotonic capture
clock, pen-over-lock-screen cursor, the DRM error dump, layer-surface resize
(a Wayland layer shell), desktop-entry limits, the flake and its Home Manager
module, and the XDG autostart note. [docs/parity](../../parity/README.md)
lists each with its status.
