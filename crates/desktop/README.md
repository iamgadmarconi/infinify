# Desktop controller ABI v1

`driftwm-desktop` builds an `rlib` and `libdriftwm_desktop.a`. Include
[`include/driftwm_desktop.h`](include/driftwm_desktop.h) from the native shell.
Use one handle per scene, with serialized access. The C boundary catches Rust
unwinds; it cannot protect against invalid pointers, use-after-free or OOM aborts.
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

All rectangles are `{origin:{x,y},size:{width,height}}`, points are `{x,y}`.
Coordinates are logical points with top-left origin and Y down. Output bounds
and pointer positions are global screen points. The AppKit shell must convert
its bottom-left coordinates before calling. Buffer dimensions/crops are pixels.
Logical window/output IDs are unsigned 64-bit integers, allocated starting at 1.
Preserve them as integers in native code.

| `command.op` | Remaining command fields | Result data |
| --- | --- | --- |
| `register_output` | `stable_id` string, `screen_bounds` rect | `output` logical ID |
| `remove_output` | `output` | `{}`; camera retained by stable identity |
| `outputs_settled` | none | `{dirty}`; sent once every display is registered: a screen-pinned window whose output is missing moves to one that is connected ([RULES.md](RULES.md#wire-contract)) |
| `attach` | `identity`, `bundle_id`, `title`, `buffer:{width,height}`, `source_rect`, optional `logical_id`, optional `world_rect`, optional `output`, optional `pointer` | `window` logical ID; for a new window also `adopted`, `effect`, `navigation`, `dirty` |
| `window_closed` | `window`, `identity`, optional `output` | `{standin, effect, navigation, dirty}` |
| `retitle` | `window`, `identity`, `title` | `{dirty}` |
| `adoption_complete` | optional `present`, an array of `{bundle_id, title}` | `{dropped, standins, dirty}` |
| `observe` | `window`, `identity`, `source_rect`, `buffer` | `{}`; never changes world geometry |
| `remove_source` | `window`, `identity`, `keep_placeholder` boolean | `{}` |
| `forget` | `window` | `{}`; removes source and world placeholder |
| `pan` | `output`, `screen_delta` point, optional `time_ms` and `source` | `{}`; positive X reveals world to right; with `time_ms` it feeds momentum |
| `pan_end` | `output`, optional `time_ms` | `{needs_frames}`; launches momentum |
| `pointer` | `output` or null, global `screen` point | `{needs_pointer, needs_frames}`; for cursor edge pan |
| `zoom_by` | `output`, global `anchor` point, `delta`, `source`, optional `phase` | `{navigation, needs_frames}`; wheel or pinch zoom at the config's speeds |
| `zoom` | `output`, `zoom` in `[0.001,1]`, global `anchor` point | `{}`; anchor world point stays fixed |
| `focus` | `window` | `effect` or null; raises logical world z-order |
| `activate` | `window`, `output` or null, `cause: click / click_release / native`, optional `identity`, `generation` | `effect` or null (absent for `click_release`), `navigation` or null, `dirty`; see [NAVIGATION.md](NAVIGATION.md#activate) |
| `clear_focus` | none | `{dirty}`; no window holds logical focus |
| `hit` | `output`, global `screen` point | `hit` object or null; it says whether the window is a `widget` or `pinned` |
| `input` | `output`, global `screen` point, expected `identity` | same hit object; rejects absent/unbound/stale target |
| `begin_drag` | `window`, `output`, optional `group` boolean (default false) | `{}` |
| `begin_resize` | `window`, `output`, `edges`, optional `group` boolean | `{}` |
| `gesture_to` | total `screen_delta` from gesture start, optional global `pointer` point | `{needs_frames}`; a drag's `pointer` arms edge pan |
| `end_gesture` | none | `{}` |
| `gesture_begin` | `kind`, `fingers`, `modifiers`, `context`, `output`, global `pointer` point, optional `doubletap`, `time_ms` | `{gesture, fired, note, navigation, effects, dirty, needs_frames, trackpad}` |
| `gesture_update` | optional `dx`, `dy`, `scale`, `rotation`, `held`; `time_ms` | the same |
| `gesture_end` | optional `cancelled`, `held`; `time_ms` | the same |
| `snapshot` | none | `outputs`, `windows`, `focused`, `placements`, `lifecycle`, `render`, `evidence`; each window with its `widget`, `pinned` and `rule`, each placement with `pinned`, `widget` and `opacity`, and both with what the window is drawn with (`kind`, `decoration` and the rest of [RENDER.md](RENDER.md#placements)) |
| `screenshot_result` | `path`, `width`, `height`; or `error` | `{reply}`: upstream's reply to the client that asked for the screenshot |
| `save` / `load` | explicit caller `path` string | `{}` |
| `load_config` | `path` string or null | `{path, exists, errors, warnings, dirty, effects}` |
| `set_platform` | `super` chord | `{super}` |
| `bindings` | none | key bindings as macOS chords, the `cycle_hold` modifiers, and each output's hot corners |
| `mouse_binding` | `trigger`, `source`, `modifiers`, `context` | `{binding}` or `{binding: null}` |
| `hot_corner` | `output`, `corner`, optional `pointer`, `held` | `{navigation, effects, dirty}` |
| `layout_changed` | `name`, `short`, `index`, `count` | `{}` |
| `state_event` | `output` or null | `{line}`: the State event line, or null when unchanged |

See [focus/cycle commands](FOCUS.md) for the additive focus ABI and
[normal-window navigation](NAVIGATION.md) for camera commands, runtime snapshots,
and the native frame-clock contract. [Camera motion](MOTION.md) covers timed
pans and momentum, edge pan, cursor edge pan and `zoom_by`.
[Actions, bookmarks and IPC](IPC.md)
covers the `action`, `ipc` and `state_event` commands, the saved bookmark map,
the event stream, and the exported `driftwm_desktop_msg` client.
[Configuration](CONFIG.md) covers the six commands from `load_config` to
`layout_changed`: DriftWM's TOML file, what of it is applied, the binding map,
outputs, hot corners, keyboard layouts, autostart, and what stands for
upstream's Linux commands. [Window lifecycle](LIFECYCLE.md) covers a window
that appears or closes by itself: adoption, placement, stand-ins,
`window_closed`, `retitle`, `adoption_complete` and the close, suspend and
relaunch actions.
[Window rules](RULES.md) covers `[[window_rules]]`, widgets and screen-pinned
windows: what a rule does to a new window, the order `placements` and `hit`
follow, what every navigation, gesture and output action does with a widget or
a pinned window, `toggle-pin-to-screen`, `move-to-bookmark`, and IPC `Pin` and
`Opacity`.
[Rendering](RENDER.md) covers what the shell's compositor draws from: the
snapshot's `render` block, what each placement is drawn with (the rule its
window mapped with, the layer and the space it is drawn in), and the
`msg screenshot` flow that ends in `screenshot_result`.
[Trackpad gestures](GESTURES.md) covers `gesture_begin`, `gesture_update` and
`gesture_end`: a libinput-shaped swipe, pinch or hold dispatched against the
`[gestures]` tables. They are apart from `begin_drag`, `begin_resize`,
`gesture_to` and `end_gesture`, the pointer's drag and resize below.

## macOS modifiers

Bindings are written in upstream's modifiers and mapped to a Mac keyboard:

- `ctrl` is Control, `alt` is Option, `shift` is Shift.
- `logo` (`super`, and `mod` when `mod_key = "super"`, upstream's default) is a
  physical chord: Control+Option unless `set_platform` chooses another subset of
  `ctrl`, `alt` and `cmd`. `{"super":"cmd"}` gives upstream's chords literally.
- A binding that holds `logo` and a modifier the chord already contains is
  displaced so it stays distinct: `ctrl` becomes Command and `alt` becomes
  Command+Shift. With the default chord `mod+ctrl+Right` is ⌃⌥⌘→ and
  `mod+alt+Right` is ⌃⌥⇧⌘→. A chord that contains Command leaves nothing to
  displace to, and such a binding is skipped with a warning.
- `mod3` has no macOS equivalent: such bindings are skipped with a warning.
- Two bindings on one physical chord: the first by upstream combo text keeps
  it, the other is reported. Control+Option+Escape is the shell's exit chord
  unless a binding claims it.

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

Verification:

```sh
cargo test -p driftwm-desktop --test navigation_flow --test navigation_actions_flow --test focus_cycle_flow --test controller_flow --test config_flow --test lifecycle_flow --test motion_flow --test gesture_flow --test rules_flow --test render_flow --locked
cargo clippy -p driftwm-desktop --all-targets -- -D warnings
cargo fmt -p driftwm-desktop --check
cargo build -p driftwm-desktop
cc -Wall -Wextra -Werror -mmacosx-version-min=26.0 \
  -Icrates/desktop/include crates/desktop/tests/abi_smoke.c \
  target/debug/libdriftwm_desktop.a -o /tmp/driftwm-desktop-abi-smoke
/tmp/driftwm-desktop-abi-smoke
```

These scenarios prove controller behavior through JSON and the exported C ABI.
They do not prove captured pixels, drawn frames, written screenshots, usable
compositing or native input delivery.
