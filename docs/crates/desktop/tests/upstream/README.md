# Navigation oracle provenance

This page describes the files in `crates/desktop/tests/upstream/` (it lives under `docs/` with the rest of the Markdown); "the directory" and the bare file names below mean that directory.

Full, unmodified source files from https://github.com/malbiruk/driftwm at
`df3de27b26c7998e8a460cffd8a4925cbed3a322` (tag `v0.21.0`), licensed
GPL-3.0-or-later, kept at their upstream paths under `src/` (for example
`src/state/navigation.rs`). `SHA256SUMS` records each file; `METHODS.json`
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

`landing_view_on` (src/state/viewport.rs) and `canvas::zoom_anchor_camera`
(src/canvas.rs, which `landing_view_on` calls as
`driftwm::canvas::zoom_anchor_camera`) execute as the original bytes; the shim
declares `mod driftwm { pub mod canvas { ... } }` to give the second that path
and adds no algorithm. The shim's per-output storage holds `camera_target`,
`zoom_target` and `zoom_animation_anchor`.

Other methods in the directory's files are not executed here, for example
`reveal_element`, `pan_minimally_to_element` and `related_to_focus` in
navigation.rs, and the pointer-constraint and edge-pan code in
viewport_animation.rs.

`crates/desktop/tests/navigation_flow.rs::source_parity_keep_reset_placements_timing_and_retarget`
compares the controller's camera and zoom, row by row, against these methods
for all nine focus placements, both window sizes, keep and reset, including a
second `keep` navigation armed while the first is in the air, which
`navigation_target_zoom` answers with `landing_view_on`'s zoom.
