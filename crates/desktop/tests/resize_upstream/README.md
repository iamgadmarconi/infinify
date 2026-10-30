# Bounded native resize oracle provenance

Full unmodified GPL-3.0-or-later sources from https://github.com/malbiruk/driftwm
at `df3de27b26c7998e8a460cffd8a4925cbed3a322` (tag `v0.21.0`), byte-identical
to `third_party/driftwm/src/grabs/resize_grab.rs` (here `resize_grab.rs`) and
`third_party/driftwm/src/handlers/compositor.rs` (here `compositor.rs`).
SHA256SUMS pins full files; BLOCKS.json pins exact byte ranges and hashes. Tests
verify both and extract unchanged blocks into the type/IO shim in
`support/resize_oracle.rs`.

Executed: original edge predicates, SizeConstraints::clamp, request displacement
and integer dimensions through clamp, and the ordinary unpinned incremental
settlement block in handle_resize_commit. The request block starts after screen
coordinate conversion; the shim supplies screen displacement directly. Aspect
ratio is disabled. Settlement supplies current position, last committed size,
and actual geometry; placement_owns_size is false. These are deliberately blocks,
not the complete resize grab, release handler, or commit handler.

No native calls, Wayland configure scheduling, client readback, capture, or
rendering execute here. Snap has its separate existing upstream oracle; this
oracle does not claim integrated snap/resize parity. Integer displacement traces
are compared. Existing floating-point reducer behavior for fractional displacement
still differs from upstream's integer truncation and is explicitly unresolved.

## Re-pin from 352333a8 (v0.19.0-3) to v0.21.0

All four executed blocks (EDGES, CLAMP, REQUEST, SETTLE) are byte-identical
at v0.21.0: the bytes at the old offsets were found exactly once in each new
file, and only their line and byte offsets moved (BLOCKS.json). What changed
upstream in these two files lies outside the blocks and does not execute here:
`SizeConstraints::for_suspended` now also has a ceiling (the chrome buffer cap,
v0.21 hardening for stand-ins), and `handlers/compositor.rs` drops an opaque
region of more than 64 rects (MAX_OPAQUE_REGION_RECTS).
