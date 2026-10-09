# Navigation oracle provenance

Full, unmodified source files from https://github.com/malbiruk/driftwm at
`352333a8fa1b22171492d4b71a54102045c9a19d`, licensed GPL-3.0-or-later.
`SHA256SUMS` records each file; `METHODS.json` pins inclusive source line ranges
and exact method-byte hashes. The navigation integration test verifies both,
extracts unchanged bodies, and compiles them with the test-only storage/type
shim. No generated extraction is committed.

Executed original methods: align_point_on, set_camera_anchor,
navigation_target_zoom, animation_factor, tick_zoom_animation_on,
tick_camera_animation_on, outer_frame_inset, Chrome::frame_size,
FocusPlacement::pull, and visual_frame_center. The shim uses the existing test
Smithay geometry adapter, per-output RefCell storage, configuration fields,
and camera/pointer side-effect sinks. Tests invoke inactive-output ticks, so
pointer delivery is not exercised. Native titlebars are already included in the
native visible frame; native traces use zero additional compositor chrome.

The full files provide provenance and surrounding context; only the enumerated
methods execute. This is not execution of upstream navigation dispatch,
Wayland/X11 integration, compositor scheduling, or native macOS rendering.
