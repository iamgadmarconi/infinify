# Normal-window navigation, ABI 1

The `normal_window_navigation` snapshot capability covers a selected normal
window's camera placement with `keep` or `reset` zoom. A UI may call the primitive
“Center selected window”. This is not upstream's complete `center-window` action:
RestoreFillElseReset, nearest-window fallback, fullscreen/pin/fill/suspended
handling and upstream input dispatch are absent. No native operation is performed.

| Command | Fields | Result |
| --- | --- | --- |
| `navigate_window` | `window`, `output`, `zoom_policy: keep / reset` | focus `effect` plus `navigation` |
| `cycle_navigate` | `output`, `backward`, `held` | existing frozen focus cycle plus Keep navigation; `{}` for empty cycle |
| `tick_navigation` | `timestamp_ns` unsigned monotonic nanoseconds | `changed_outputs`, `needs_frames` |
| `cancel_navigation` | `output` | `{}` |
| `set_navigation_context` | `output`, `usable_rect_local`, `focus_placement`, `camera_speed`, `outer_gap` | `{}`; cancels that output's flight |

Navigation returns `{output,generation,target_camera,target_zoom,animating}`.
The generation is a controller-lifetime monotonic counter; load does not rewind it.
The response is the armed destination, not a claim of native focus success.
[Focus effects](FOCUS.md) remain separately acknowledged and superseded. A failed
or stale focus result never rewinds the camera. Invalid requests roll back all
logical focus, effects, flights, context, and frame-clock state.

The current pose lives only in `Scene.Viewport`. Snapshot `outputs` contains that
pose; `navigation.flights` separately shows optional camera/zoom targets, anchor
and generation. The target camera is cleared by the anchored zoom tick, because
that tick performs the camera movement itself. Flight entries disappear together
on arrival or cancellation. Context and clock are inspectable runtime state.

The whole output, center placement, camera speed 0.3 and outer gap 0 are defaults.
Once a [config](CONFIG.md) is loaded, placement, camera speed and outer gap are
the config's (`focus_placement`, `navigation.camera_speed`, `snap.outer_gap`)
and only `usable_rect_local` is taken from this command.
Usable rectangles use output-local coordinates, including their nonzero origin,
and must fit inside the output. Placement accepts center, top, bottom, left,
right, top_left, top_right, bottom_left, bottom_right. Speed must be finite in
`(0,1]`; gap finite in `[0,1e12]`. Frame coordinates remain fractional. A window's
world rectangle already includes its complete native frame/titlebar; additional
compositor border is zero. The internal alignment equation preserves upstream's
`outer_gap - border`, including negative insets, without exposing mutable chrome.
Oversize frames fall back to center separately on each axis.

Initialize the clock with `tick_navigation` before the first navigation and keep
it updated while idle. Every call computes one elapsed time for all outputs,
capped at 33 ms. The first call establishes the clock with zero elapsed time;
repeated timestamps use zero elapsed time, and decreasing timestamps reject
atomically. Arrival checks still run on zero-time ticks, as upstream does. A
native integration must schedule frames while `needs_frames` is true and apply
the resulting Scene placements; there is no native scheduling/input loop here.

The source multi-output order is zoom tick then camera tick, with factor
`1-(1-speed)^(dt*60)`. Arrival uses pre-tick displacement and strict thresholds:
zoom delta below 0.001 and anchor distance squared below 0.25. Keep also arms an
anchor and zoom target at the current zoom. Retargeting starts at the current
animated pose. Pan/zoom cancel only their output; installing a drag/resize cancels
all outputs. Navigation during an active gesture rejects. Output re-registration
or disconnect cancels its runtime flight/context. Reconnect uses its current or
saved camera and never resumes a flight.

Save schema 1 is unchanged: saves contain current cameras, not destinations,
and no flight, clock, navigation generation, or context. Load clears all of these
runtime states (retaining generation monotonicity on the same handle).

## Evidence and limits

`navigation_flow` drives exported C ABI requests and compares trajectories to
verbatim methods mechanically extracted at test time from pinned full upstream
sources. Full-file SHA-256 and per-method line ranges/hashes are verified before
compilation. See [oracle provenance](tests/upstream/README.md). The shim supplies
storage/types and records side effects; it does not implement replacement
navigation equations. Tests cover Keep/Reset, all placements, asymmetric usable
areas, oversize frames, strict arrival boundaries, fractional native geometry,
60/120 Hz intervals, zero and capped intervals, retargeting, multiple outputs,
intermediate-camera hit testing, focus failure/supersession, cancellation, and
save/load. One pure helper test covers negative border inset, which native ABI
commands cannot express, against the same source oracle boundary values.

Parity claims apply only to source-representable traces. This executes selected
original methods, not the whole upstream compositor or its scheduler. It proves
no native rendering, capture, input delivery, or usable third-party compositing.

The shell now supplies a frame timer, and selected-window/cycle
actions behind `--experimental-native-navigation`. Its separate headless check
executes the actual Objective-C coordinator and input-order policy with this C ABI;
it does not execute native focus or prove real shortcut delivery. See the
[shell integration scope](../../native/desktop/README.md).

## View actions

The same six handlers, and the bookmark actions, are also reachable by upstream
action string and IPC request: see [actions, bookmarks and IPC](IPC.md).

Six camera-only commands adapt upstream's `PanViewport`, `HomeToggle`, `ZoomIn`,
`ZoomOut`, `ZoomReset` and `ZoomToFit` (`src/input/actions.rs` at the pinned
commit, with `try_restore_overview`, `fit_to_bbox`, `zoom_to_anchored`, and
`min_zoom` from `src/state/navigation.rs`). They are ordinary ABI 1 commands with
no snapshot capability or flag of their own. Each arms the same per-output flight
that `tick_navigation` advances; none touches a window, a source, logical or
native focus, or another output.

| Command | Fields | Destination |
| --- | --- | --- |
| `pan_viewport` | `output`, `direction: up / down / left / right / up_left / up_right / down_left / down_right` | camera moves `pan_step / zoom` world points along the unit vector |
| `home_toggle` | `output` | world origin under the usable center at zoom 1, or back |
| `zoom_in` | `output` | zoom × `zoom.step`, at most 1 |
| `zoom_out` | `output` | zoom ÷ `zoom.step`, at least the dynamic minimum |
| `zoom_reset` | `output` | zoom 1 |
| `zoom_to_fit` | `output` | every window inside the usable area, or back |

The reply is `{"navigation":{output,generation,target_camera,target_zoom,animating}}`
when a flight was armed and `{"navigation":null}` when the action has nothing to
do. `target_zoom` is the flight's zoom target; for `pan_viewport`, which carries
none, it is the current zoom. Generations share the window-navigation counter.
An unknown output rejects, and every action rejects with
`navigation during active gesture` while a drag or resize gesture is installed,
before changing any state. A destination whose viewport would leave the ±1e12
world, camera or far corner, rejects with `navigation target out of bounds`
instead of arming a flight that no tick could apply. `navigate_window` and
`cycle_navigate` still check the camera only.

All geometry is logical: the output's current camera and zoom, its
`screen_bounds` size, the navigation context's `usable_rect_local`, and window
world rectangles. Observed or original native rectangles are never read. The
screen anchor is the usable rectangle's center in output-local points
(upstream `usable_center_screen`); the world point under it is
`camera + center / zoom`. Actions read the current pose, not a pending flight's
destination, with one exception below.

- `pan_viewport` keeps a pending camera target and adds one step to it, so
  presses made before a frame extend the destination instead of restarting from
  the partially animated camera. A pending zoom target and anchor are dropped:
  zoom stays where the animation had brought it.
- `home_toggle` is at home when `|zoom - 1| < 0.01` and the world origin is
  inside the whole output (edges inclusive). Away from home it remembers the
  current pose and flies to camera `-center`, zoom 1. At home it flies back to
  the remembered pose and forgets it; with nothing remembered it is a no-op.
- `zoom_in`, `zoom_out` and `zoom_reset` anchor the world point under the usable
  center. Step targets pass through upstream's `snap_zoom` (±0.05 around 1).
  `zoom_in` at zoom 1 still arms a flight to the same zoom, as upstream does.
- `zoom_to_fit` flies back to a remembered pose if one is pending. Otherwise it
  fits the bounding box of every Scene window, detached placeholders included,
  centers the box on the usable center, and remembers the pose it left. With no
  windows it is a no-op.

The steps are the [config](CONFIG.md)'s `navigation.pan_step`, `zoom.step` and
`zoom.fit_padding`; upstream's defaults are 100, 1.1 and 80 screen points.
`zoom_to_fit` also fits the config's `navigation.anchors`, as points. The fit
zoom is `min((usable - 2·padding) / box)` per axis, clamped to `[0.001, 1]`;
the dynamic minimum is half the fit zoom, floored at 0.001, with upstream's 5×5
box at (-2,-2) when there are no windows.

`driftwm_canvas::policy` works in upstream's integer logical pixels and leaves
the rounding to its caller. A window's world rectangle becomes the smallest
enclosing integer rectangle: the origin is floored and the far edge ceiled, so
a fit never clips a fractional frame. Output and usable extents are rounded to
the nearest integer. A value outside `i32`, including a bounding-box extent,
rejects the command instead of saturating.

Return poses are runtime state per output, visible as `navigation.home_returns`
and `navigation.overview_returns` in the snapshot. A pending fit return is
disarmed by `pan`, `zoom`, `navigate_window`, an armed `cycle_navigate`,
`pan_viewport`, `zoom_in`, `zoom_out`, `zoom_reset`, and leaving for home; only
`home_toggle` consumes a home return. Cancelling a flight, starting a gesture,
changing the navigation context, or re-registering a connected output leaves
both in place. Removing the output drops both. Neither is saved: save schema 1
is unchanged and load starts with none.

Differences from upstream:

- Upstream's pinch and pointer zoom clamp to the dynamic minimum. The `zoom`
  command here still accepts the static 0.001 floor, so a pose can already sit
  below the minimum. `zoom_out` is then a complete no-op (`{"navigation":null}`,
  fit return untouched) rather than a flight that zooms in.
- `HomeToggle`'s fullscreen legs (instant snap, fullscreen restore, pointer
  warp), `ZoomToFitSnapped`, and momentum are absent. Every Scene window counts
  as a canvas window.
- Upstream's `execute_action` prelude commits an in-progress focus cycle before
  any non-cycle action. These commands leave logical focus and a held cycle
  exactly as they were.

### Evidence and limits

`view_actions_flow` drives the six commands through the exported C ABI and
`tick_navigation` until `needs_frames` is false, on an output whose global
origin is not (0,0) and whose usable rectangle is asymmetric, beside a second
output whose pose must not change. It checks the settled fit against Scene
placements and the 80 px padding, exact toggle returns, the fixed world point on
every zoom frame, extended pan destinations, each fit-return disarm except
`cycle_navigate` (which arms through the same path as `navigate_window`), the
`zoom_out` deviation, gesture, schema and out-of-world rejection, save/load and
output removal. Expected values are derived by hand from the contract above; unlike
`navigation_flow`, upstream's action bodies are not executed as an oracle, so
parity with them is by reading, not by differential test. The pure helpers they
call are covered by the canvas crate's `policy_flow`.

This is controller ABI evidence only. It shows no key binding, shell dispatch,
frame scheduling, native rendering, capture, or input delivery. The default
shell binds these commands to toolbar buttons and global shortcuts and ticks
their flights with its own 60 Hz timer, without the experimental flag; that path
is built but unrun. See the [shell README](../../native/desktop/README.md).
