# Canvas snapping contract

## Source and oracle

`driftwm_core::layout::snap` is the single magnetic snap module used by
`Scene` gestures and the desktop keyboard walk. It owns stop discovery,
candidate ranking, latching and break cooldown. Frozen gesture membership and
cluster geometry remain in canvas `src/{layout,gestures,cluster_resize}.rs`.
The module takes and returns pure world geometry/state; no seam or adapter is
needed. Canvas has a production dependency on platform-neutral core, never on
desktop or native code.

Retained upstream stop/keyboard geometry comes from DriftWM
(<https://github.com/malbiruk/driftwm>, GPL-3.0-or-later) v0.21.0,
`df3de27b26c7998e8a460cffd8a4925cbed3a322`. Product latch and discovery live in
the new, non-ported `crates/core/src/layout/snap/magnetic.rs`; they were adapted
from `352333a8fa1b22171492d4b71a54102045c9a19d` and include product cooldown
fix `71246bf`. `docs/crates/core/PORT.md` lists every retired upstream item.

`snap_parity` is no longer an executable oracle: it names the retired duplicate
interactive latch and already contradicted the fixed cooldown rule. It, core's
upstream snap tests (including the inline module), and desktop's
`resize_upstream/` are untouched and deliberately left for the later test phase.
Replace latch parity with behavior through `Scene::begin_drag` / `drag_to` and
`Scene::begin_resize` / `resize_to`: once broken away from a stop, motion away
must never jump back; cooldown must survive while the same stop is still the
candidate; release resistance, threshold strictness, first-target ties, edge
families, and frozen cluster membership must retain their contracts. Keep
independent behavioral coverage of the shared stop and keyboard queries.
No tests were run or changed during consolidation.

The `[snap]` configuration defaults of v0.20 (`corners` on,
`outer_gap` 12) are the controller's configuration, not `SnapOptions`' or
`DragGesture::with_alignment`'s, whose defaults stay as below.

## Parameters

`SnapOptions` has three fields. Defaults are gap 12 world
points, distance 24 at zoom 1, and cluster adjacency tolerance 1. The controller
sets only the first two, from the config's `[snap]` table, and builds the rest
with `SnapOptions::default()`: `adjacency_tolerance` is always 1.0 there. It
uses distance `24 / current_zoom` and release force `32 / current_zoom` on every
gesture update (with a config that does not say otherwise); the gap stays in
world coordinates. The controller's total screen displacement still uses the
gesture-start zoom.

Opposite-edge snapping requires strict perpendicular overlap. Engagement and
ranking measure distance to the neighbor's edge **before** the gap is applied;
engagement uses `< distance`, and equal candidates keep the first target in scene
order. Only the primary window attracts during a group drag. All movement uses
`begin_drag` and `drag_to`, including latches, cooldown and optional alignment.
A group drag freezes membership at the start; setting its threshold to zero
translates the group without snapping.

`Scene::set_snapping(id, false)` takes a window out of all of it, as upstream's
snap rectangles leave out widgets and screen-pinned windows: it is no snap
target for a dragged or resized edge, joins no cluster, and `cluster` of it is
itself alone. The exclusion lasts for the session and is not saved; every
window snaps until told otherwise. `Scene::raise(id)` raises without
focusing.

`DragGesture::with_alignment(corners, centers)` enables parallel-edge and midpoint
alignment; both default off, as in upstream. Alignment requires no perpendicular
overlap and a perpendicular gap strictly less than `gap + distance`.
`ResizeGesture::with_same_edge` enables parallel-edge resize alignment; upstream
has no center resize candidate family. X resolves before Y, using a held Y latch
for the first perpendicular range and the resolved X range for the second.
Release occurs at `>= break_force` on retreat from engagement or overshoot past
the snap target. Cooldown clears only beyond the threshold **and** when that stop is no longer
the candidate; another candidate may engage on the breaking update. Break force zero
is accepted as upstream does.

Resize snapping excludes the primary and statically shifted cluster members.
Unclassified members remain eligible targets. The snapshot and collision bonds
remain fixed during a gesture. `with_constraints(min, max)` captures optional
visible-frame bounds (zero means unconstrained); dimensions clamp before snapping,
with minimum then maximum precedence and a final one-point floor after snapping.
As upstream, snapping can cross a declared bound. The controller currently has no
native client-constraint input, so its bounds remain unconstrained. The returned
rectangle is the canvas request, not an observation of native acceptance.

## Deliberate boundaries with upstream

- Canvas geometry and deltas remain `f64`. Upstream's move grab truncates its final
  positions to `i32`; its resize grab truncates pointer deltas, and its resize snap
  routine truncates resulting sizes. The retired differential resize traces compared integer
  inputs and zero added chrome. Fractional canvas behavior preserves the existing
  API and is not claimed to match upstream pixel rounding.
- The existing fractional cluster resolver retains its arithmetic tolerance and
  atomic error on an unsettled cascade; upstream uses ceil/floor integer pushes
  and returns after a 2N iteration bound. Integer component/bond traces pass, but
  this change does not claim general cluster rounding or pathological cascade
  parity.
- Upstream move grabs derive motion from the current canvas pointer location minus
  the starting canvas point; controller `screen_delta / start_zoom` is its existing
  input contract. Current-zoom snap distances are verified independently. Camera
  motion, output crossing and dynamic pointer conversion remain outside this port.
- Missing or externally moved captured windows fail atomically here. Upstream's
  live cluster-member resolution can drop closed windows during a grab.
- Optional alignment and explicit bounds are exposed through the typed canvas API;
  the desktop JSON protocol continues to use upstream defaults. Native chrome
  acquisition, constraint acquisition, configure acknowledgement, aspect locking,
  native window ownership and event routing are outside these tests.
