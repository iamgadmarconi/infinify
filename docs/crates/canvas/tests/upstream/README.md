# Executable upstream oracle

Bare `src/…` paths on this page name files of upstream DriftWM, not of `crates/canvas/src/`.

This page describes the files in `crates/canvas/tests/upstream/` (it lives under `docs/` with the rest of the Markdown); "this directory" below means that directory.

`stage/mod.rs` is a byte-for-byte copy of `src/stage/mod.rs` from
[malbiruk/driftwm](https://github.com/malbiruk/driftwm), commit
`df3de27b26c7998e8a460cffd8a4925cbed3a322` (tag `v0.21.0`). It remains
GPL-3.0-or-later; see the repository `LICENSE` and `NOTICE`. Do not format or
edit it. Verify it from this directory:

```sh
shasum -a 256 -c SHA256SUMS
```

`stage/element.rs` is not an upstream copy: it is a harness trait adapter, in
which value IDs implement only the element queries `Stage` uses.
`crates/canvas/tests/support/stage_oracle.rs` compiles the full original `Stage` with `rustc`
as an executable, without `cfg(test)`, so upstream's separate unit-test modules
are not loaded. It supplies geometry storage and default construction through
`crates/canvas/tests/support/canvas_shim.rs`, the `SnapRect` data shape, and an input/output
trace driver. No MRU, cycle, removal or stacking algorithm is in the adapter;
the driver calls upstream operations.

`cargo test -p driftwm-canvas --test stage_parity parity_` compares the public
`Scene` trace with this executable after every operation. It covers map, raise,
frozen history, fresh and backward wrap, an excluded current window, clamped
removal, explicit interruption and cancel, and remove and re-add identity.
Fractional production geometry is checked unchanged alongside the integer
oracle geometry. Fullscreen, fit, fill, pin and modal relationships are compiled
but not modeled or claimed as implemented by production. This establishes
bounded controller-state parity, never native focus or complete Alt-Tab
behavior.

The former snap and cluster parity harness was removed after the upstream
interactive snap API was retired. See `../../SNAPPING.md` for the current
geometry and parity boundary.
