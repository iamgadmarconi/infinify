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
