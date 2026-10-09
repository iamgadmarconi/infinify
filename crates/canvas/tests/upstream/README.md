# Executable upstream oracle

`snap.rs` and `cluster.rs` are byte-for-byte copies from
[malbiruk/driftwm](https://github.com/malbiruk/driftwm), commit
`352333a8fa1b22171492d4b71a54102045c9a19d`, paths `src/layout/snap.rs` and
`src/layout/cluster.rs`. They remain GPL-3.0-or-later; see the repository
`LICENSE` and `NOTICE`. Do not format or edit these oracle files.

Verify the copies from this directory:

```sh
shasum -a 256 -c SHA256SUMS
```

Run the public Scene differential traces from the repository root:

```sh
cargo test -p driftwm-canvas --test snap_parity parity_
```

The integration test compiles these original algorithms directly. The `parity_`
filter excludes the upstream cluster module's own 35 unit tests. Production code
does not import the oracle. The drag wrapper follows
`src/state/cluster_snapshot.rs::snap_move_location`; resize invokes upstream
`snap_resize_edges` directly with zero added chrome (canvas rectangles already
include the visible frame). Cluster component discovery and integer bond-reversal
traces invoke upstream `cluster_of` and `resolve_cluster_shifts` directly.
Static resize classifications and constraint application order are source-cited
fixtures from `src/state/cluster_snapshot.rs::cluster_snapshot_for_resize_with_rects`
and `src/grabs/resize_grab.rs::{SizeConstraints::clamp,apply_motion}`; those
Smithay-dependent wrappers are not themselves executed by this harness.

These traces prove the compared canvas outputs for the tested inputs. They do
not establish native macOS behavior, all upstream compositor paths, or exhaustive
floating-point/integer equivalence. See `../../SNAPPING.md` for the boundary.

## Canvas policy oracle

`canvas.rs` is also copied byte-for-byte from `src/canvas.rs` at the same pinned
commit. `policy_flow` compiles the complete unchanged file, substituting only
Smithay geometry storage, ordinary arithmetic/conversion, and config Direction
through `tests/support/canvas_shim.rs`. Run:

```sh
cargo test -p driftwm-canvas --test policy_flow policy_
```

The filter skips upstream's own 44 unit tests. Public policy pipelines compare
fit/dynamic minimum/camera centers, visibility/culling, nearest direction,
bookmark selection, zoom anchoring, and momentum event/tick traces with the
original helper bodies. The shim contains no camera, selection, or momentum
algorithm. The eight direction vectors are independently copied from
`src/config/types.rs::Direction::to_unit_vec`; that source file's SHA-256 at the
pinned commit is
`d709bb9c4adc8212ff38e21b60676ceddbbed24b0ab184acb7745255d78fb1b2`.
The test shim does not establish equivalence to all Smithay geometry operations.
Only the field storage, tuple construction, Point addition/subtraction, and i32
to f64 casts needed to compile the original file are implemented.

See `../../POLICY.md` for the public helper contracts and integration boundaries.

## Stage oracle

`stage/mod.rs` is the complete byte-for-byte `src/stage/mod.rs` from the same
pinned upstream commit, GPL-3.0-or-later. `stage/element.rs` is explicitly a harness
trait adapter, not an upstream copy: value IDs implement only the element queries
used by Stage. `tests/support/stage_oracle.rs` compiles the full original Stage
with rustc as an executable (without cfg(test), so upstream's separate unit-test
modules are not loaded). It supplies geometry storage/default construction and
the SnapRect data shape, plus an input/output trace driver; no MRU, cycle, removal,
or stacking algorithm is in the adapter. The driver calls upstream operations.

`cargo test -p driftwm-canvas --test stage_parity parity_ --locked` compares the
public Scene trace with this executable after every operation. It covers map,
raise, frozen history, fresh/backward wrap, an excluded current window, clamped
removal, explicit interruption/cancel, and remove/re-add identity. Fractional
production geometry is checked unchanged alongside integer oracle geometry.
Fullscreen, fit, fill, pin and modal relationships are compiled but not modeled or
claimed as implemented by production. This establishes bounded controller-state
parity, never native focus or complete Alt-Tab behavior.
