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
