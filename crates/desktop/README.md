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
| `attach` | `identity`, `bundle_id`, `title`, `buffer:{width,height}`, `source_rect`, optional `logical_id`, optional `world_rect` | `window` logical ID |
| `observe` | `window`, `identity`, `source_rect`, `buffer` | `{}`; never changes world geometry |
| `remove_source` | `window`, `identity`, `keep_placeholder` boolean | `{}` |
| `forget` | `window` | `{}`; removes source and world placeholder |
| `pan` | `output`, `screen_delta` point | `{}`; positive X reveals world to right |
| `zoom` | `output`, `zoom` in `[0.001,1]`, global `anchor` point | `{}`; anchor world point stays fixed |
| `focus` | `window` | `effect` or null; raises logical world z-order |
| `hit` | `output`, global `screen` point | `hit` object or null |
| `input` | `output`, global `screen` point, expected `identity` | same hit object; rejects absent/unbound/stale target |
| `begin_drag` | `window`, `output`, optional `group` boolean (default false) | `{}` |
| `begin_resize` | `window`, `output`, `edges`, optional `group` boolean | `{}` |
| `gesture_to` | total `screen_delta` from gesture start | `{}` |
| `end_gesture` | none | `{}` |
| `snapshot` | none | `outputs`, `windows`, `focused`, `placements`, `evidence` |
| `save` / `load` | explicit caller `path` string | `{}` |

See [focus/cycle commands](FOCUS.md) for the additive focus ABI and
[normal-window navigation](NAVIGATION.md) for camera commands, runtime snapshots,
and the native frame-clock contract. [Actions, bookmarks and IPC](IPC.md)
covers the `action` and `ipc` commands, the saved bookmark map, and the exported
`driftwm_desktop_msg` client.

`edges` is `left`, `right`, `top`, `bottom`, `top_left`, `top_right`,
`bottom_left` or `bottom_right`. One gesture is active per controller. Motion
uses gesture-start zoom and real canvas snapshot/hysteresis/group semantics.
The snap threshold is 24 screen points, break force 32 screen points, and gap
12 world points. Threshold and break force use current output zoom on each update;
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

`attach` without `logical_id` creates a new world window. Its initial world frame
is `world_rect` if supplied, otherwise `source_rect`. A supplied `logical_id`
explicitly rebinds an existing unattached placeholder; `world_rect` is then
forbidden, preserving saved geometry. PID/title matching is never automatic.
Existing live bindings must first be detached before replacing their identity.

Each placement is a separate `(window,output)` instance, ordered bottom-to-top
within each output. Fields: `screen_rect` (full projection), `clip_rect` (visible
screen bounds), `world_local_crop`, `buffer_crop` (pixel crop, null for detached
placeholders), and `source` (null or fresh ephemeral observation). Source includes
`identity`, `buffer`, `original_rect`, and `observed_rect`. Native moves update only
`observed_rect`; world resizing scales the entire observed source into the world
rectangle. Crops and input therefore scale proportionally between these spaces.

Hit objects contain `window`, `output`, `identity`, `local` (observed native
window-local logical points), `buffer_local` pixels, `native_screen`, and
`requires_native_revalidation:true`. Hits use topmost world z-order. An unbound
placeholder blocks input with an error rather than clicking through it.

Saves contain scene geometry, app bundle/title metadata and cameras keyed by
stable display identity. They contain no PID, window number, process birth,
connection, capture buffer, credentials, or gesture. Reload retains unattached
world placeholders and detached camera records; the shell must register actual
connected displays, then explicitly attach selected fresh sources. Output IDs
and cameras survive disconnect/reconnect and restart. Writes use a private
sibling temporary file, fsync, atomic rename and parent-directory sync. A directory
sync error can be reported after the rename committed. Parent directories must
already exist. Loads are bounded at 32 MiB and never modify the input file.

Verification:

```sh
cargo test -p driftwm-desktop --test navigation_flow --test focus_cycle_flow --test controller_flow --locked
cargo clippy -p driftwm-desktop --all-targets -- -D warnings
cargo fmt -p driftwm-desktop --check
cargo build -p driftwm-desktop
cc -Wall -Wextra -Werror -mmacosx-version-min=26.0 \
  -Icrates/desktop/include crates/desktop/tests/abi_smoke.c \
  target/debug/libdriftwm_desktop.a -o /tmp/driftwm-desktop-abi-smoke
/tmp/driftwm-desktop-abi-smoke
```

These scenarios prove controller behavior through JSON and the exported C ABI.
They do not prove captured pixels, usable compositing or native input delivery.
