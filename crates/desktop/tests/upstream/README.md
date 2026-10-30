# Navigation oracle provenance

Full, unmodified source files from https://github.com/malbiruk/driftwm at
`df3de27b26c7998e8a460cffd8a4925cbed3a322` (tag `v0.21.0`), licensed
GPL-3.0-or-later; they are byte-identical to `third_party/driftwm/<path>` (the
vendored snapshot, same paths). `SHA256SUMS` records each file; `METHODS.json`
pins inclusive source line ranges and exact method-byte hashes. The navigation
integration test verifies both, extracts unchanged bodies, and compiles them
with the test-only storage/type shim. No generated extraction is committed.

Executed original methods: align_point_on, set_camera_anchor,
navigation_target_zoom, landing_view_on, animation_factor,
tick_zoom_animation_on, tick_camera_animation_on, outer_frame_inset,
Chrome::frame_size, FocusPlacement::pull, visual_frame_center and
canvas::zoom_anchor_camera. The shim uses the existing test Smithay geometry
adapter, per-output RefCell storage, configuration fields, and camera/pointer
side-effect sinks. Tests invoke inactive-output ticks, so pointer delivery is
not exercised. Native titlebars are already included in the native visible
frame; native traces use zero additional compositor chrome.

The full files provide provenance and surrounding context; only the enumerated
methods execute. This is not execution of upstream navigation dispatch,
Wayland/X11 integration, compositor scheduling, or native macOS rendering.

## Re-pin from 352333a8 (v0.19.0-3) to v0.21.0

Compared method by method (the bytes of each enumerated range at the old pin
against the new files):

- Byte-identical, only their line numbers moved: set_camera_anchor,
  animation_factor, tick_zoom_animation_on, tick_camera_animation_on,
  outer_frame_inset, Chrome::frame_size, FocusPlacement::pull,
  visual_frame_center.
- align_point_on: the code is unchanged; one doc-comment line inside it now
  reads "the edge fill produces" where it said "the edge fit and fill produce"
  (v0.20 made fit ignore `snap.outer_gap`), so its range and hash changed.
- navigation_target_zoom: changed. It returned `output_state(output).zoom`
  for a non-reset navigation; it now returns `self.landing_view_on(output).1`,
  the zoom the view is heading to, because the live zoom would stop a zoom
  animation where the frame caught it (v0.20: "Alt-Tab, center-nearest and other
  navigations started during a zoom animation freezing the zoom partway").
- New to the list: `landing_view_on` (src/state/viewport.rs) and
  `canvas::zoom_anchor_camera` (src/canvas.rs), which it calls as
  `driftwm::canvas::zoom_anchor_camera`. Both execute as the original bytes;
  the shim declares `mod driftwm { pub mod canvas { ... } }` to give the second
  that path and adds no algorithm. The shim's per-output storage already held
  `camera_target`, `zoom_target` and `zoom_animation_anchor`, so it did not grow.
- Files in the directory that changed upstream outside the executed methods
  (navigation.rs gained `reveal_element`, `pan_minimally_to_element`,
  `related_to_focus` and others; viewport_animation.rs the pointer-constraint and
  edge-pan changes): not executed here.

`tests/navigation_flow.rs::source_parity_keep_reset_placements_timing_and_retarget`
compares the controller's camera and zoom, row by row, against these methods
for all nine focus placements, both window sizes, keep and reset, including a
second `keep` navigation armed while the first is in the air (the case the
`landing_view_on` change decides). Against the old v0.19 methods the controller
failed that comparison (1419.59 != 1402.04) once it adopted the landing zoom;
against the v0.21.0 methods it passes.
