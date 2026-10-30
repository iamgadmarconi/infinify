# Pure upstream canvas policies

`driftwm_canvas::policy` ports the pure helper policies from
`malbiruk/driftwm`, commit `352333a8fa1b22171492d4b71a54102045c9a19d`,
`src/canvas.rs`, under GPL-3.0-or-later. Its differential oracle
(`tests/policy_flow.rs`) now compiles v0.21.0's unchanged `src/canvas.rs`
(commit `df3de27b26c7998e8a460cffd8a4925cbed3a322`,
`third_party/driftwm/src/canvas.rs`) and passes; v0.21.0 added
`minimal_reveal_camera` and `leading_edge_camera`, which this module does not
port, and made `closest_point_on_rect` sum in f64, which it does not (it still
sums in i32; the traced inputs do not reach the difference). It does not change Scene, controller,
native-window, persistence, or session behavior. The existing `Momentum` helper
also remains unchanged. This module is a foundation for separately reviewed
integration.

## Public contracts

- `PixelPoint`, `PixelSize`, and `PixelRect` preserve upstream integer logical
  geometry. They have no implicit conversion from fractional Scene frames. Future
  callers must choose the source-equivalent rounding at the integration boundary.
- `all_windows_bbox`, `zoom_to_fit`, and `dynamic_min_zoom` retain integer bounds,
  screen-space padding, the 0.001–1.0 fit range, the empty-layout 5×5 rectangle at
  (-2,-2), and the minimum limit at half the fit zoom (floored at 0.001).
- `viewport_center` and `camera_for_center` use user-facing Y-up center coordinates.
  `visible_fraction` uses a rectangle's intersection area; `is_point_visible`
  includes both viewport edges. `visible_canvas_rect` takes an already rounded
  integer camera and uses ceil(viewport/zoom)+2 extents.
- `find_nearest` accepts arbitrary item identities and all eight upstream
  directions, excludes the supplied item, uses a ±45° cone and `distance²/dot`
  score, and retains iterator order on ties. `closest_point_on_rect` supplies the
  geometric target where the caller needs an edge instead of a center. This does
  not select which live/native targets a controller should include.
- `active_bookmark` consumes names mapped to Y-up `[x,y]` points, independent of
  Scene's existing saved-camera bookmark representation. It considers visible
  points, uses the caller's usable-area center, breaks ties by name, and keeps a
  visible incumbent unless another point is strictly more than 10% closer.
- `snap_zoom` uses upstream's strict 0.05 dead zone around 1.0, without additional
  clamping. `zoom_anchor_camera` returns the camera preserving a supplied anchor.
- `VelocityTracker` uses input event timestamps, an inclusive 80 ms sample window,
  wrapping u32 timestamp differences, and total displacement divided by elapsed
  time. Fewer than two samples or equal timestamps produce zero velocity.
- `MomentumState` uses the original launch/coast/stop state machine. Each tick
  moves by velocity×dt before applying speed-dependent drift. Speed below 15
  stops; exactly 15 still yields a tick. Drift is mapped through geometric
  half-life scaling and capped retention exactly as upstream. `DEFAULT_DRIFT=0.5`
  comes from `src/config/mod.rs`'s navigation default; the added `Default`
  implementation selects it. `new(drift)` leaves parameter validation to callers,
  matching the pure upstream constructor. A zero drift still yields its first
  coasting displacement before velocity becomes zero.

Inputs preserve upstream behavior rather than adding Scene validation: callers
must supply meaningful zoom/viewports and integer geometry whose arithmetic fits
i32. Zero extents and empty collections retain the upstream helper's own special
cases. No new blanket validation changes NaN, clamp, overflow, or timestamp
semantics. The safe front/back lookup in `launch_velocity` replaces upstream's
unreachable unwraps after its sample-count check without changing results.

## Verification boundary

`tests/policy_flow.rs` calls the public helper API and compares pipelines/traces
with the entire unchanged upstream `canvas.rs`, compiled through a test-only
Smithay geometry/Direction shim. The original file's SHA-256 is recorded in
`tests/upstream/SHA256SUMS`; source provenance and reproduction commands are in
`tests/upstream/README.md`. Float results in compared traces use exact bit checks.
Upstream's embedded unit tests are filtered out; these are focused integration
tests of the exported pure contracts.

This does not prove usable native application behavior, fullscreen/fit state
transitions, output selection, target eligibility, gesture event ordering,
bookmark persistence conversion, animations, or restore/relaunch policy. Dynamic
minimum zoom and fit are not installed into existing Scene/controller mutations.
The new eight-direction policy and upstream momentum do not silently replace the
older Scene four-direction API or exponential momentum implementation.
